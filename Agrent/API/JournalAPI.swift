import Foundation

enum JournalAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/journal" }

    static var listPath: String { "\(base)?limit=50" }

    /// The route returns a paginated envelope when `limit` is present and a
    /// bare array otherwise, so both have to be readable — `listPath` sends
    /// `limit` today, but the cache holds bytes written by whatever the app
    /// asked for at the time.
    ///
    /// Separated from the fetch so that CACHED bytes go through exactly this
    /// decode too. A cache that reads its contents with a simpler decoder than
    /// the network path is a cache that fails only when offline, which is the
    /// worst time to discover it.
    ///
    /// ── The shape is DECIDED, not discovered by failing ──
    ///
    /// This used to be `try envelope` / `catch is DecodingError` / `try bare
    /// array`, and that fallback was too wide in both directions.
    ///
    /// It would have swallowed the loud failure `PagedResponse` exists to
    /// raise: a body with neither `rows` nor `items` throws on purpose, and a
    /// blanket catch turns that back into a second attempt and a confusing
    /// error from the wrong decoder. And a MALFORMED ELEMENT — one entry with
    /// a bad date — was reported as "this is not an envelope", sending the
    /// next person to look at pagination instead of at the entry.
    ///
    /// JSON tells us which it is without guessing: an array starts with `[`.
    static func decodeList(from data: Data) async throws -> [LogEntry] {
        let first = data.first { !$0.isJSONWhitespace }
        if first == UInt8(ascii: "[") {
            return try await APIClient.shared.decode(data, as: [LogEntry].self)
        }
        return try await APIClient.shared.decode(
            data, as: PagedResponse<LogEntry>.self
        ).items
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

private extension UInt8 {
    /// The four bytes JSON allows between tokens (RFC 8259 §2). Needed
    /// because a payload may be pretty-printed or start with a newline, and
    /// `data.first` would then see whitespace rather than the `[` or `{`
    /// that says which shape this is.
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
