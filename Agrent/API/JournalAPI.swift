import Foundation

enum JournalAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/journal" }

    static var listPath: String { "\(base)?limit=50" }

    /// The route returns a paginated envelope when `limit` is present and a
    /// bare array otherwise. Ask for the envelope so paging has somewhere to
    /// go later; decode defensively because the slice must not break if the
    /// shape is the other one.
    ///
    /// Separated from the fetch so that CACHED bytes go through exactly this
    /// decode too. A cache that reads its contents with a simpler decoder than
    /// the network path is a cache that fails only when offline, which is the
    /// worst time to discover it.
    static func decodeList(from data: Data) async throws -> [LogEntry] {
        do {
            return try await APIClient.shared.decode(data, as: JournalPage.self).rows
        } catch is DecodingError {
            return try await APIClient.shared.decode(data, as: [LogEntry].self)
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
