import Foundation

enum ExchangeAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/exchange" }

    /// Envelope: `{ rows, nextCursor }`.
    static var listingsPath: String { listingsPath(ExchangeQuery()) }

    /// PARITY GAP 2. The web drives this query with `q`, `minTonnes`,
    /// `maxTonnes`, `limit` and `cursor`; the app sent no query string at
    /// all, so it showed an unfiltered first page with no way to search and
    /// no way to reach page two.
    ///
    /// On a board that grows, "no way to reach page two" degrades
    /// SILENTLY: the screen keeps looking correct while holding less and
    /// less of the truth.
    ///
    /// ── The search term is the one value here that can be personal ──
    ///
    /// CFNetwork writes the full request URL to the unified log and the app
    /// cannot suppress it. A cursor and a tonnage are not personal; a
    /// free-text `q` is whatever the operator typed, and somebody searching
    /// for a seller by name puts that name in the log.
    ///
    /// Shipped anyway, and this is the reasoning rather than an oversight:
    /// there is no POST search route, so the alternative is not "send it
    /// more safely", it is "do not offer search". The exposure is the
    /// operator's own input, on their own device, in a log that needs
    /// device access to read — the same exposure the web has in browser
    /// history. What must NEVER go here is a third party's data the
    /// operator did not type, which is why an assignee filter would have to
    /// wait for a route that takes a body.
    static func listingsPath(_ query: ExchangeQuery) -> String {
        var items = ["limit=\(query.limit)"]
        if let q = query.escaped(query.text) { items.append("q=\(q)") }
        if let min = query.minTonnes { items.append("minTonnes=\(min)") }
        if let max = query.maxTonnes { items.append("maxTonnes=\(max)") }
        if let cursor = query.escaped(query.cursor) { items.append("cursor=\(cursor)") }
        return "\(base)/listings?" + items.joined(separator: "&")
    }

    /// A BARE ARRAY — different envelope from `listings`, same domain.
    static var myListingsPath: String { "\(base)/my-listings" }

    /// A BARE ARRAY. Empty in production, so the element shape is unobserved.
    static var inquiriesPath: String { "\(base)/inquiries" }

    /// Measured: the detail route returns a FLAT listing object, identical in
    /// shape to one row of the list — no envelope, no extra fields. So it
    /// decodes as `ExchangeListing` and needs no type of its own.
    static func listingPath(_ id: String) -> String { "\(base)/listings/\(id)" }

    static func decodeListings(from data: Data) async throws -> ExchangeListingPage {
        try await APIClient.shared.decode(data, as: ExchangeListingPage.self)
    }

    static func decodeMyListings(from data: Data) async throws -> [OwnExchangeListing] {
        try await APIClient.shared.decode(data, as: [OwnExchangeListing].self)
    }

    static func decodeInquiries(from data: Data) async throws -> [ExchangeInquiry] {
        try await APIClient.shared.decode(data, as: [ExchangeInquiry].self)
    }

    /// NOT EXERCISED. This creates a production row AND emails the seller
    /// tenant's admins, so it ships built and unfired by deliberate decision:
    /// the first real operator send is the first real test. Nothing in
    /// development or CI may call it.
    ///
    /// No `Idempotency-Key`, and that is correct rather than an omission. The
    /// DOMAIN is idempotent by construction — `@@unique([listingId,
    /// inquirerTenantId])` means a tenant can express interest in a listing at
    /// most once — which is stronger than a header, because it holds even
    /// against a client that never sends one.
    static func createInquiry(listingID: String, message: String) async throws -> ExchangeInquiry {
        try await APIClient.shared.post(
            "\(base)/inquiries",
            body: CreateInquiry(listingId: listingID, message: message),
            as: ExchangeInquiry.self
        )
    }
}

struct CreateInquiry: Encodable, Sendable {
    let listingId: String
    let message: String
}

/// What the listings board is being asked for.
struct ExchangeQuery: Equatable, Sendable {
    var text: String = ""
    var minTonnes: Int?
    var maxTonnes: Int?
    var cursor: String?
    var limit: Int = 50

    /// Any filter at all, which is what the "clear" affordance keys on.
    var isFiltered: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            || minTonnes != nil || maxTonnes != nil
    }

    /// The same query with paging reset. A filter change must NOT carry the
    /// old cursor: it is positional against the previous result set, so
    /// reusing it appends page two of a different search.
    var firstPage: ExchangeQuery {
        var copy = self
        copy.cursor = nil
        return copy
    }

    /// `APIClient.url(for:)` takes the query VERBATIM — its header says the
    /// caller owns percent-encoding any value it interpolates. A search
    /// term is arbitrary operator input, so this is not optional.
    func escaped(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        )
    }
}
