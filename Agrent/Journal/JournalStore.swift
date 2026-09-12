import Foundation
import Observation

@Observable
@MainActor
final class JournalStore {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var entries: [LogEntry] = []
    private(set) var phase: Phase = .idle

    func load() async {
        phase = .loading
        do {
            entries = try await JournalAPI.list()
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The key is minted ONCE here and survives every retry of this create, so
    /// a lost response cannot produce two diary rows for one operator action.
    func create(_ draft: CreateLogEntry) async throws {
        let key = UUID().uuidString
        let saved = try await JournalAPI.create(draft, idempotencyKey: key)
        entries.insert(saved, at: 0)
    }
}
