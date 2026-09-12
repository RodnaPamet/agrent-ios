import Foundation

enum JournalAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/journal" }

    static func list() async throws -> [LogEntry] {
        // The route returns a paginated envelope when `limit` is present and a
        // bare array otherwise. Ask for the envelope so paging has somewhere to
        // go later; decode defensively because the slice must not break if the
        // shape is the other one.
        do {
            return try await APIClient.shared
                .get("\(base)?limit=50", as: JournalPage.self).items
        } catch is DecodingError {
            return try await APIClient.shared.get("\(base)?limit=50", as: [LogEntry].self)
        }
    }

    /// `idempotencyKey` is generated once by the CALLER and reused across
    /// retries of the same logical create. Generating it here would mint a new
    /// one per attempt and defeat the dedupe entirely.
    static func create(_ entry: CreateLogEntry, idempotencyKey: String) async throws -> LogEntry {
        try await APIClient.shared.post(
            base, body: entry, as: LogEntry.self, idempotencyKey: idempotencyKey
        )
    }
}
