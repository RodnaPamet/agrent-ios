import Foundation
import Observation

@Observable
@MainActor
final class JournalStore {
    private(set) var state: LoadState<[LogEntry]> = .loading

    var entries: [LogEntry] { state.value ?? [] }

    func load() async {
        // Only blank the screen when there is nothing on it. Dropping to
        // .loading during a pull-to-refresh would replace a perfectly good
        // list with a spinner, which reads as the list having been lost.
        if state.value == nil { state = .loading }

        state = await CachedResource.load(JournalAPI.listPath) { data in
            try await JournalAPI.decodeList(from: data)
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
