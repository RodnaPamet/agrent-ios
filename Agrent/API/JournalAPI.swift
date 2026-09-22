import Foundation

enum JournalAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/journal" }

    static var listPath: String { path(cursor: nil) }

    /// ── A CURSOR IN A QUERY STRING, and the rule it appears to break ──
    ///
    /// ROADMAP, Phase 0: "any future endpoint passing an id or anything
    /// personal must use a header or a body, never a query parameter",
    /// because CFNetwork writes the full request URL to the unified log
    /// from Apple's own subsystems and the app cannot suppress it.
    ///
    /// A cursor is a record id, so read literally that rule forbids this.
    /// The rule as written draws the wrong line, and this is the place to
    /// say so: **CFNetwork logs the whole URL, PATH INCLUDED.** The tenant
    /// slug is already in every path this app sends. A query parameter is
    /// not more exposed than a path segment; they are the same exposure.
    ///
    /// So the honest rule is "nothing personal in a URL AT ALL" rather than
    /// "nothing in the query". An opaque pagination cursor and a page size
    /// are not personal — they identify a row, not a person, and resolving
    /// one needs the bearer token anyway. A name, an email or an assignee
    /// filter would be, in either position, and those still must go in a
    /// header or a body.
    static func path(cursor: String?) -> String {
        guard let cursor, !cursor.isEmpty else { return "\(base)?limit=50" }
        // Percent-encoded by the caller, because `APIClient.url(for:)` takes
        // the query VERBATIM — its header says so, and a cursor is opaque
        // server output that may legitimately contain `+` or `=`.
        let escaped = cursor.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? cursor
        return "\(base)?limit=50&cursor=\(escaped)"
    }

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
    static func decodeList(from data: Data) async throws -> JournalSlice {
        let first = data.first { !$0.isJSONWhitespace }
        if first == UInt8(ascii: "[") {
            // The no-`limit` branch: a bare array, and therefore everything
            // there is. No cursor means no "load more", which is correct —
            // there is no more.
            let rows = try await APIClient.shared.decode(data, as: [LogEntry].self)
            return JournalSlice(entries: rows, nextCursor: nil)
        }
        let page = try await APIClient.shared.decode(
            data, as: PagedResponse<LogEntry>.self
        )
        return JournalSlice(entries: page.items, nextCursor: page.nextCursor)
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

/// One page of the journal, plus the way to ask for the next.
///
/// PARITY GAP 6. The list was `?limit=50` with no cursor and no "load
/// more", so a tenant past fifty entries saw a truncated history and
/// NOTHING ON SCREEN SAID SO. That is the worst shape a limit can take:
/// a short list and a complete list look identical, so the operator has
/// no way to know the difference — on the register the ДНЕВНИК PDF is
/// generated from.
struct JournalSlice: Equatable, Sendable {
    let entries: [LogEntry]
    let nextCursor: String?

    var hasMore: Bool { nextCursor != nil }
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
