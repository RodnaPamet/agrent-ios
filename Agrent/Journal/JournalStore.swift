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
        case .failed(let message):
            nextCursor = nil
            state = .failed(message)
        case .loading:
            state = .loading
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

    /// The key is minted ONCE here and survives every retry of this create, so
    /// a lost response cannot produce two diary rows for one operator action.
    func create(_ draft: CreateLogEntry) async throws {
        let key = UUID().uuidString
        let saved = try await JournalAPI.create(draft, idempotencyKey: key)

        // Keep whatever freshness the list already had. A create succeeding
        // does NOT mean the list caught up with the server — it means we know
        // about one more row than we did. Promoting the list to .fresh here
        // would quietly drop a staleness warning the operator still needs.
        //
        // Not shown under a filter it does not meet (`JournalFilter.admits`):
        // that row would vanish on the next refresh, which reads as a lost
        // entry. It is saved either way; clearing the filter shows it.
        // Under a crop filter the phone cannot tell; the server can. Asked
        // without holding the sheet open, because the entry is saved either
        // way, and the list's own guards drop the answer if the filter moves.
        guard filter.decidesLocally else {
            Task { await load() }
            return
        }
        guard filter.admits(saved, linkedTo: draft.locationIds ?? []) else { return }
        if case .loaded(var rows, let freshness) = state {
            rows.insert(saved, at: 0)
            state = .loaded(rows, freshness)
        } else {
            state = .loaded([saved], .fresh)
        }
    }
}
