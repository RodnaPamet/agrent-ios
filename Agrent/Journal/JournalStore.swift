import Foundation
import Observation

@Observable
@MainActor
final class JournalStore {
    private(set) var state: LoadState<[LogEntry]> = .loading

    /// Non-nil when the server says there is another page.
    private(set) var nextCursor: String?

    private(set) var loadingMore = false

    /// Set when a "load more" fails. Kept separate from `state`: the pages
    /// already on screen are still good, and replacing a working list with
    /// an error because page three timed out would lose data the operator
    /// can read.
    private(set) var loadMoreError: String?

    /// Counts the server's answers, not the cache's: a swiped treatment
    /// stays hidden until one arrives (`TreatmentRemoval.listRead`).
    private(set) var freshReads = 0

    var entries: [LogEntry] { state.value ?? [] }
    var hasMore: Bool { nextCursor != nil }

    /// What the list is narrowed to (#252). Changed through `apply(_:)`,
    /// which asks the server again.
    private(set) var filter = JournalFilter()

    /// «Изчисти филтрите», from the summary row and the filtered empty state.
    func clearFilters() async {
        await apply(JournalFilter())
    }

    /// A new filter is a new question. The rows on screen answered the old
    /// one, so they go and the spinner shows. A filtered summary above the
    /// previous answer's rows would describe rows it never chose.
    func apply(_ next: JournalFilter) async {
        guard next != filter else { return }
        filter = next
        state = .loading
        nextCursor = nil
        loadMoreError = nil
        await load()
    }

    func load() async {
        // Only blank the screen when there is nothing on it. Dropping to
        // .loading during a pull-to-refresh would replace a perfectly good
        // list with a spinner, which reads as the list having been lost.
        if state.value == nil { state = .loading }
        loadMoreError = nil

        // A refresh restarts paging from the top. Keeping an old cursor
        // across a reload would append page two of a list that no longer
        // exists — the rows shift as entries are added, and the cursor is
        // positional against the old ordering.
        //
        // ── The answer is kept only if the question still stands ──
        //
        // `asked` is the filter this request was built from. If the operator
        // has applied another one by the time it answers, it is dropped: a
        // slow unfiltered page landing after a fast filtered one would
        // otherwise put the whole diary under the filter's summary.
        let asked = filter
        let path = JournalAPI.path(filter: asked, cursor: nil)

        // ONLY THE UNFILTERED FIRST PAGE IS CACHED, as on Борса
        // (`ExchangeListingsStore.load`). The cache is keyed on the path, and
        // a period's instants move every day, so filtered pages would pile up
        // as entries no one reads again. Offline, a filter is a question that
        // needs the server; the unfiltered diary is what is worth having
        // with no signal.
        if asked.isActive {
            let loaded: LoadState<JournalSlice>
            do {
                let data = try await APIClient.shared.data(for: path)
                loaded = .loaded(try await JournalAPI.decodeList(from: data), .fresh)
            } catch {
                loaded = .failed(UserMessage.text(for: error))
            }
            if filter == asked { publish(loaded) }
        } else {
            await CachedResource.loadShowingCacheFirst(path) { data in
                try await JournalAPI.decodeList(from: data)
            } publish: { [weak self] loaded in
                guard let self, self.filter == asked else { return }
                self.publish(loaded)
            }
        }
    }

    private func publish(_ loaded: LoadState<JournalSlice>) {
        switch loaded {
        case .loaded(let slice, let freshness):
            nextCursor = slice.nextCursor
            state = .loaded(slice.entries, freshness)
            if freshness == .fresh { freshReads &+= 1 }
        case .failed(let message):
            nextCursor = nil
            state = .failed(message)
        case .loading:
            state = .loading
        }
    }

    /// The treatments kept on the phone that the journal shows above its
    /// entries (#324): this person's (`OutboxStore.pending` holds no one
    /// else's), made on the farm open NOW, and not already in the list.
    ///
    /// ── Not already in the list ──
    ///
    /// A save whose answer was lost is kept, but it may have landed: then the
    /// reload behind the sheet brings the server's row, under the same
    /// handle, while the outbox still holds the copy that will be answered
    /// with it. Shown twice, one treatment reads as two on a register.
    ///
    /// ── Under every filter ──
    ///
    /// The person's own unsent work is not an entry the server filtered, and
    /// hiding it under «Филтри» reads as lost.
    nonisolated static func waiting(in pending: [PendingOperation], farm: String?,
                                    listed: [LogEntry]) -> [PendingOperation] {
        guard let farm else { return [] }
        let handles = Set(listed.compactMap { $0.treatment?.treatmentGroupId })
        return pending.filter { $0.treatment != nil && $0.tenantSlug == farm && !handles.contains($0.id) }
    }

    /// This farm's kept treatments that came back short, by handle (#326).
    /// The server's row stands in for such a treatment in the list (`waiting`
    /// leaves it out), so the server's row is where the rest is said to be
    /// missing. It counts the ДНЕВНИК entries, and on its own reads like a
    /// treatment sent for fewer parcels.
    nonisolated static func partial(in pending: [PendingOperation],
                                    farm: String?) -> [String: PendingOperation.QueuedTreatment] {
        guard let farm else { return [:] }
        return pending.reduce(into: [:]) { found, row in
            if row.tenantSlug == farm, let treatment = row.treatment, treatment.recorded != nil {
                found[row.id] = treatment
            }
        }
    }

    /// The next page, appended.
    ///
    /// NOT cached. `CachedResource` keys on the path, so every page would
    /// become its own cache entry and the offline read would be page one
    /// plus whichever later pages happened to have been fetched — a
    /// history with holes in it, presented as continuous. Page one is the
    /// field case and it stays cached; the rest are network-only and
    /// simply absent offline, which is honest.
    func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        loadMoreError = nil
        defer { loadingMore = false }

        // The same filter as page one, or page two would be a page of a
        // different list. Dropped if the filter changed while it was asked.
        let asked = filter
        do {
            let data = try await APIClient.shared.data(for: JournalAPI.path(filter: asked, cursor: cursor))
            let slice = try await JournalAPI.decodeList(from: data)
            guard filter == asked else { return }

            // Append, de-duplicated by id. A cursor is positional, so an
            // entry created between two page fetches shifts the window and
            // can repeat a row. A diary showing one entry twice is not a
            // cosmetic problem — it is a register that looks like it
            // recorded the same operation twice.
            var seen = Set(entries.map(\.id))
            let fresh = slice.entries.filter { seen.insert($0.id).inserted }

            if case .loaded(let existing, let freshness) = state {
                state = .loaded(existing + fresh, freshness)
            } else {
                state = .loaded(fresh, .fresh)
            }
            nextCursor = slice.nextCursor
        } catch {
            guard filter == asked else { return }
            loadMoreError = UserMessage.text(for: error)
        }
    }
}
