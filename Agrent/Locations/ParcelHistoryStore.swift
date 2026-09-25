import Foundation
import Observation

/// A parcel's archive, with each of its three lists paged on its own.
///
/// ── The hazard this type exists to contain ──
///
/// "A stale or malformed cursor RESTARTS that list rather than erroring."
/// That is the server's documented behaviour and it is the right choice for a
/// server — a 400 over a cursor from yesterday would strand a screen. But it
/// means a client asking for OLDER rows can receive the NEWEST ones instead,
/// with a 200 and a perfectly valid body.
///
/// Appended blindly, that is an infinite list: page 1 arrives again, its
/// cursor is handed back, page 1 arrives again. The rows repeat, the list
/// grows, nothing errors, and the screen looks like a farm with the same spray
/// recorded forty times. So every append is deduplicated by id, and a page
/// that carries NOTHING NEW stops that section for good.
///
/// ── Paging one section must ignore the other two ──
///
/// `GET /history` answers with all three lists on every call. Asking for older
/// operations therefore also returns the FIRST page of seasons and weeds. A
/// merge that took the whole envelope would re-append those, so `loadOlder`
/// takes only the section it asked about — correct whether the server sends
/// the others or not.
@Observable
@MainActor
final class ParcelHistoryStore {
    private(set) var state: LoadState<Archive> = .loading
    private let parcelID: String

    init(parcelID: String) { self.parcelID = parcelID }

    /// One section of the archive.
    ///
    /// `cursor != nil` is NOT "has more". The server returns a cursor for the
    /// last row of the page it just sent, so a list whose rows divide exactly
    /// by the page size hands back a cursor for a page that turns out to be
    /// empty. `exhausted` is the honest flag and it is set by what ARRIVED,
    /// not by what was promised.
    struct Section<Item: Identifiable & Equatable & Sendable>: Equatable, Sendable
    where Item.ID == String {
        var items: [Item]
        var cursor: String?
        var isLoadingOlder = false
        var exhausted = false
        var failure: String?

        var canLoadOlder: Bool { cursor != nil && !exhausted && !isLoadingOlder }

        /// Deduplicated by id, and a page with nothing new ends the section.
        ///
        /// The empty-page case and the restart case are handled by the same
        /// line on purpose: both mean "there is nothing further to show here",
        /// and a client cannot tell them apart from the outside — nor does it
        /// need to.
        mutating func appendOlder(_ incoming: [Item], cursor next: String?) {
            let known = Set(items.map(\.id))
            let fresh = incoming.filter { !known.contains($0.id) }
            if fresh.isEmpty {
                exhausted = true
                return
            }
            items.append(contentsOf: fresh)
            cursor = next
            if next == nil { exhausted = true }
        }
    }

    struct Archive: Equatable, Sendable {
        var parcel: ParcelHistory.ParcelRef
        var seasons: Section<CropSeason>
        var operations: Section<ParcelHistoryOperation>
        var weeds: Section<WeedObservation>

        init(_ page: ParcelHistory) {
            parcel = page.parcel
            seasons = Section(items: page.cropSeasons, cursor: page.cropSeasonsCursor)
            operations = Section(items: page.operations, cursor: page.operationsCursor)
            weeds = Section(items: page.weedObservations, cursor: page.weedObservationsCursor)
        }

        /// Nothing recorded at all — which is a real state for a parcel that
        /// was imported yesterday, and must not read as a failure.
        var isEmpty: Bool {
            seasons.items.isEmpty && operations.items.isEmpty && weeds.items.isEmpty
        }
    }

    /// Which list a "load older" is for. Not an index: the three sections hold
    /// different types and nothing generic can dispatch between them.
    enum Part: Sendable { case seasons, operations, weeds }

    // MARK: - The first page

    func load() async { await load(showCachedFirst: true) }

    /// Pull-to-refresh REPLACES the archive rather than merging into it.
    ///
    /// Older pages already fetched are dropped, and that is deliberate: the
    /// point of the gesture is a current answer, and stitching a fresh first
    /// page onto pages read ten minutes ago produces a list with a gap in the
    /// middle that nothing on screen could explain.
    func refresh() async { await load(showCachedFirst: false) }

    private func load(showCachedFirst: Bool) async {
        if state.value == nil { state = .loading }
        let path = ParcelHistoryAPI.historyPath(parcelID: parcelID)
        await CachedResource.loadShowingCacheFirst(path, showCachedFirst: showCachedFirst) { data in
            Archive(try await ParcelHistoryAPI.decodeHistory(from: data))
        } publish: { [weak self] in self?.state = $0 }
    }

    // MARK: - Older pages

    /// NOT cached and NOT retried.
    ///
    /// `CachedResource` keys on the path, and every older page has its own
    /// path because the cursor is in the query — so caching them would fill
    /// the response cache with pages that are only ever read once. The first
    /// page is the one worth caching and it is the one that is ETagged.
    func loadOlder(_ part: Part) async {
        guard var archive = state.value, let freshness = state.freshness else { return }
        guard let cursor = cursor(for: part, in: archive) else { return }

        setLoading(true, for: part, in: &archive)
        state = .loaded(archive, freshness)

        do {
            let path = ParcelHistoryAPI.historyPath(
                parcelID: parcelID,
                seasonsBefore: part == .seasons ? cursor : nil,
                operationsBefore: part == .operations ? cursor : nil,
                weedsBefore: part == .weeds ? cursor : nil
            )
            let page = try await ParcelHistoryAPI.decodeHistory(
                from: try await APIClient.shared.data(for: path)
            )
            guard var current = state.value else { return }
            merge(page, into: &current, for: part)
            state = .loaded(current, state.freshness ?? freshness)
        } catch {
            guard var current = state.value else { return }
            setLoading(false, for: part, in: &current)
            setFailure(UserMessage.text(for: error), for: part, in: &current)
            state = .loaded(current, state.freshness ?? freshness)
        }
    }

    /// Takes ONLY the section that was asked about. See the type's header.
    private func merge(_ page: ParcelHistory, into archive: inout Archive, for part: Part) {
        switch part {
        case .seasons:
            archive.seasons.isLoadingOlder = false
            archive.seasons.failure = nil
            archive.seasons.appendOlder(page.cropSeasons, cursor: page.cropSeasonsCursor)
        case .operations:
            archive.operations.isLoadingOlder = false
            archive.operations.failure = nil
            archive.operations.appendOlder(page.operations, cursor: page.operationsCursor)
        case .weeds:
            archive.weeds.isLoadingOlder = false
            archive.weeds.failure = nil
            archive.weeds.appendOlder(page.weedObservations, cursor: page.weedObservationsCursor)
        }
    }

    private func cursor(for part: Part, in archive: Archive) -> String? {
        switch part {
        case .seasons: archive.seasons.canLoadOlder ? archive.seasons.cursor : nil
        case .operations: archive.operations.canLoadOlder ? archive.operations.cursor : nil
        case .weeds: archive.weeds.canLoadOlder ? archive.weeds.cursor : nil
        }
    }

    private func setLoading(_ value: Bool, for part: Part, in archive: inout Archive) {
        switch part {
        case .seasons: archive.seasons.isLoadingOlder = value
        case .operations: archive.operations.isLoadingOlder = value
        case .weeds: archive.weeds.isLoadingOlder = value
        }
    }

    private func setFailure(_ text: String?, for part: Part, in archive: inout Archive) {
        switch part {
        case .seasons: archive.seasons.failure = text
        case .operations: archive.operations.failure = text
        case .weeds: archive.weeds.failure = text
        }
    }
}
