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
        let loaded = await CachedResource.load(JournalAPI.listPath) { data in
            try await JournalAPI.decodeList(from: data)
        }
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

        do {
            let data = try await APIClient.shared.data(for: JournalAPI.path(cursor: cursor))
            let slice = try await JournalAPI.decodeList(from: data)

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
        if case .loaded(var rows, let freshness) = state {
            rows.insert(saved, at: 0)
            state = .loaded(rows, freshness)
        } else {
            state = .loaded([saved], .fresh)
        }
    }
}
