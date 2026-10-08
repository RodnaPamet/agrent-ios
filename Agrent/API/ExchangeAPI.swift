import Foundation

enum ExchangeAPI {
    private static var base: String { "\(FarmPath.root)/exchange" }

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
    static func listingPath(_ id: String) -> String { "\(base)/listings/\(segment(id))" }

    static func decodeListings(from data: Data) async throws -> ExchangeListingPage {
        try await APIClient.shared.decode(data, as: ExchangeListingPage.self)
    }

    static func decodeMyListings(from data: Data) async throws -> [OwnExchangeListing] {
        try await APIClient.shared.decode(data, as: [OwnExchangeListing].self)
    }

    static func decodeInquiries(from data: Data) async throws -> [ExchangeInquiry] {
        try await APIClient.shared.decode(data, as: [ExchangeInquiry].self)
    }

    /// NOT EXERCISED: a listing is published to every tenant in the
    /// platform. Built, wired,
    /// and the first real send is the owner's.
    static func createListing(_ draft: CreateExchangeListing) async throws -> Data {
        try await APIClient.shared.postReturningData(
            "\(base)/listings", body: draft, idempotencyKey: nil
        )
    }

    // MARK: - Messaging (agrent-ios#114)
    //
    // Nine operations: the inbox, one conversation page, open-a-thread, send,
    // mark read, close, block, unblock, and retract one message. Every WRITE
    // below ships BUILT AND UNFIRED, like `createListing`: each one is seen by
    // another farm (a thread appears in their inbox the moment it is OPENED,
    // with no message sent), so nothing in development, CI or A11yShots may
    // call one against production. Under the UI test seam every write is
    // answered 501 `WRITE_REFUSED`, which is the backstop, not the rule.
    //
    // NONE OF THESE IS CACHED. The web keeps `/exchange/threads` out of its
    // persistent cache on purpose — private text from another farm must not
    // outlive a lost phone — and `ResponseCache` survives sign-out. Readers
    // call `APIClient.shared.data(for:)` and decode here; nothing hands these
    // paths to `CachedResource`.
    //
    // ── What goes in a URL ──
    //
    // CFNetwork logs full request URLs. Thread and message ids are opaque and
    // appear in logged paths already. The only query values are a page size
    // and an opaque cursor — base64url of `<timestamp>|<row id>`, so an id in
    // effect, and nothing a person typed. Message TEXT only ever travels in a
    // body.

    /// The page size the server accepts: whole numbers, 1 to 100.
    ///
    /// The server clamps out-of-range values itself, but it runs a bare
    /// `Number()` with no integer check, so `2.5` or `NaN` would reach Prisma's
    /// `take` and come back a 500. Taking an `Int` and clamping here means this
    /// client can only ever send a value the server handles.
    static let messagingPageSizes = 1...100

    static func clampedPageSize(_ limit: Int) -> Int {
        min(max(limit, messagingPageSizes.lowerBound), messagingPageSizes.upperBound)
    }

    /// The inbox's first page with the server's default size (100), and no
    /// query at all — the key `FixtureCatalogue` serves the inbox under.
    static var threadsPath: String { threadsRoot }

    /// Spelled once, and not as `threadsPath` inside the builders below: that
    /// name is both a property and a function here, and a bare reference to
    /// it from inside one of them is the kind of overload a reader has to
    /// stop and resolve.
    private static var threadsRoot: String { "\(base)/threads" }

    /// The inbox, paged. `cursor` is the previous page's `nextCursor`; nil or
    /// blank asks for the first page. `limit` nil leaves the server's default.
    ///
    /// Keyset paging over `lastMessageAt`, which MOVES when a message arrives:
    /// a thread bumped between two page fetches jumps above the cursor and is
    /// missing from the later page. Refresh from the top and dedupe by id.
    static func threadsPath(cursor: String?, limit: Int? = nil) -> String {
        withQuery(threadsRoot, [
            limit.map { "limit=\(clampedPageSize($0))" },
            ExchangeQuery.escape(cursor).map { "cursor=\($0)" },
        ])
    }

    /// The newest page of one conversation — the page a poll asks for.
    static func threadPath(_ threadID: String) -> String {
        "\(threadsRoot)/\(segment(threadID))"
    }

    /// An OLDER page: `before` is the previous page's `olderCursor`.
    ///
    /// A malformed `before` returns the NEWEST page with a 200, not an error —
    /// which is why `Conversation.mergeOlder` treats a page with nothing new
    /// as the end rather than appending it.
    static func threadPath(_ threadID: String, before: String?, limit: Int? = nil) -> String {
        withQuery(threadPath(threadID), [
            limit.map { "limit=\(clampedPageSize($0))" },
            ExchangeQuery.escape(before).map { "before=\($0)" },
        ])
    }

    /// Open (or find) this farm's thread on a listing. Under `listings`, not
    /// `threads`: the thread does not have an id until this answers.
    static func openThreadPath(listingID: String) -> String {
        "\(base)/listings/\(segment(listingID))/thread"
    }

    static func messagesPath(threadID: String) -> String {
        "\(threadPath(threadID))/messages"
    }

    static func readPath(threadID: String) -> String {
        "\(threadPath(threadID))/read"
    }

    static func closePath(threadID: String) -> String {
        "\(threadPath(threadID))/close"
    }

    /// POST blocks, DELETE unblocks — one path, two verbs.
    static func blockPath(threadID: String) -> String {
        "\(threadPath(threadID))/block"
    }

    /// Retract: under `messages`, not under the thread. A message id is
    /// enough for the server to find its thread.
    static func messagePath(messageID: String) -> String {
        "\(base)/messages/\(segment(messageID))"
    }

    // MARK: Messaging — reads

    static func decodeThreads(from data: Data) async throws -> ExchangeThreadPage {
        try await APIClient.shared.decode(data, as: ExchangeThreadPage.self)
    }

    static func decodeThread(from data: Data) async throws -> ExchangeThread {
        try await APIClient.shared.decode(data, as: ExchangeThread.self)
    }

    // MARK: Messaging — writes (BUILT AND UNFIRED)

    /// NOT EXERCISED. Creates a thread the listing's owner sees at once, as
    /// UNREAD, with no message in it and no notification — an outward-facing
    /// write on its own. Built and unfired; nothing in development or CI may
    /// call it.
    ///
    /// No body is read by the route; `{}` is sent, as the web does, because
    /// `APIClient` has no bodiless POST. No `Idempotency-Key`: the domain is
    /// idempotent — one thread per (listing, inquiring PERSON) since agri-saas
    /// #1323 — and a second call answers 200 `created: false` with the same
    /// id. So does a second call RACING the first: since agri-saas #1418
    /// (live 2026-10-08, read off `/api/health`) the insert is `ON CONFLICT DO
    /// NOTHING` followed by a re-read, where the race used to answer 409.
    static func openThread(listingID: String) async throws -> ExchangeThreadOpened {
        let data = try await APIClient.shared.postReturningData(
            openThreadPath(listingID: listingID), body: NoBody(), idempotencyKey: nil
        )
        return try await APIClient.shared.decode(data, as: ExchangeThreadOpened.self)
    }

    /// NOT EXERCISED. Delivers a message to another farm and notifies its
    /// owners and admins. Built and unfired; nothing in development or CI may
    /// call it.
    ///
    /// ── The key is the caller's, and it is REQUIRED ──
    ///
    /// `APIClient.post` defaults `idempotencyKey` to a fresh UUID per CALL,
    /// which would make every retry a new message. So this takes the key
    /// explicitly, from `MessageSendKeys`, which keeps one key per (thread,
    /// exact text) across retries and drops it on any 201.
    ///
    /// The server matches a replay on (sending farm, key) ALONE — not the
    /// thread, not the text — so a key reused for different text returns the
    /// ORIGINAL message as `replayed: true`. That is why the key is minted,
    /// never derived from the text: the same «Да» sent to two threads would
    /// otherwise collapse into the first. `MessageSendKey` can only be
    /// minted, so an empty or text-derived key cannot reach this call.
    ///
    /// `text` is sent as given; pass `MessageBody.validate`'s trimmed text.
    static func sendMessage(
        threadID: String, text: String, idempotencyKey: MessageSendKey
    ) async throws -> ExchangeMessageSent {
        try await APIClient.shared.post(
            messagesPath(threadID: threadID),
            body: SendExchangeMessage(body: text),
            as: ExchangeMessageSent.self,
            idempotencyKey: idempotencyKey.value
        )
    }

    /// NOT EXERCISED against production from development or CI: it moves the
    /// read pointer of EVERY member of this farm, not only this user's.
    ///
    /// No body (the route reads none) and no key: the pointer only ever moves
    /// forward to the server's own now, so a repeat is harmless. Callers
    /// SWALLOW its failure — the seam answers it 501, and a failed mark is
    /// not something a farmer can act on.
    static func markRead(threadID: String) async throws -> ExchangeThreadRead {
        let data = try await APIClient.shared.postReturningData(
            readPath(threadID: threadID), body: NoBody(), idempotencyKey: nil
        )
        return try await APIClient.shared.decode(data, as: ExchangeThreadRead.self)
    }

    /// NOT EXERCISED. Either party may close; it refuses nothing afterwards
    /// and the next message from either side reopens it. Idempotent — a
    /// second close answers `alreadyClosed: true` — so no key.
    static func closeThread(threadID: String) async throws -> ExchangeThreadClosed {
        let data = try await APIClient.shared.postReturningData(
            closePath(threadID: threadID), body: NoBody(), idempotencyKey: nil
        )
        return try await APIClient.shared.decode(data, as: ExchangeThreadClosed.self)
    }

    /// NOT EXERCISED. The listing owner only (`BLOCK_SELLER_ONLY` otherwise).
    /// Blocks the other FARM across every listing between the two, not just
    /// this thread — which is why the screen confirms first. Idempotent
    /// (`alreadyBlocked`), so no key.
    static func blockParty(threadID: String) async throws -> ExchangePartyBlocked {
        let data = try await APIClient.shared.postReturningData(
            blockPath(threadID: threadID), body: NoBody(), idempotencyKey: nil
        )
        return try await APIClient.shared.decode(data, as: ExchangePartyBlocked.self)
    }

    /// NOT EXERCISED. Lifts the farm-pair block everywhere. Always answers
    /// `{blocked: false}`, blocked or not. A DELETE carries no key.
    static func unblockParty(threadID: String) async throws -> ExchangePartyUnblocked {
        let data = try await APIClient.shared.deleteReturningData(blockPath(threadID: threadID))
        return try await APIClient.shared.decode(data, as: ExchangePartyUnblocked.self)
    }

    /// NOT EXERCISED. Irreversible from the app — the screen confirms first.
    /// A soft delete: the message becomes a tombstone for both parties. A
    /// message already retracted answers 200 too. The 404 is NOT swallowed
    /// (`deleteReturningData`'s rule): here it means "not visible to this
    /// farm", and the id came from a page this client just read.
    static func retractMessage(messageID: String) async throws -> ExchangeMessageRetracted {
        let data = try await APIClient.shared.deleteReturningData(
            messagePath(messageID: messageID)
        )
        return try await APIClient.shared.decode(data, as: ExchangeMessageRetracted.self)
    }

    // MARK: Messaging — helpers

    /// `{}` — what the web sends to the routes that read no body.
    private struct NoBody: Encodable {}

    /// An id as ONE path segment. Server ids are cuids and pass through
    /// unchanged; the escaping is so that an id that ever carried a `/` or a
    /// `?` could not move the request to a different route or start a query
    /// — `APIClient.url(for:)` splits on the first `?`. This used to be its
    /// own escaper, and was double-encoded for exactly the characters it
    /// escaped until `url(for:)` took the path verbatim (#122).
    private static func segment(_ id: String) -> String {
        URLEscape.segment(id)
    }

    private static func withQuery(_ path: String, _ items: [String?]) -> String {
        let present = items.compactMap { $0 }
        return present.isEmpty ? path : path + "?" + present.joined(separator: "&")
    }
}

/// Post an offer to the board.
///
/// ── NEVER RETRIED ──
///
/// The route honours no idempotency and there is no natural key, so a
/// replay puts a SECOND OFFER on a board every tenant in the platform can
/// see, under this farm's name. Withdrawing it is a public act.
///
/// Same shape as the cost row and worse: a duplicated cost is wrong on
/// one farm's books, a duplicated offer is wrong in front of everyone
/// else's. So: no auto-retry, no queue, the button cannot be pressed
/// twice, and a TIMEOUT is reported as UNKNOWN rather than as failure —
/// after a lost response the app does not know whether the listing
/// exists, and "it failed" invites the one action that makes it worse.
struct CreateExchangeListing: Encodable, Sendable {
    let side: String
    let kind: String

    /// A CANONICAL SLUG, constrained server-side: the field transforms
    /// through `normalizeCommodity` and a miss is a 400 quoting the whole
    /// canonical list. So the picker is driven from the same ten the web's
    /// own modal uses, which is what makes the two incapable of drifting —
    /// and what stops the phone posting a slug the board cannot filter on.
    let commodity: String

    /// `boundedDecimal` is `z.union([z.number(), z.string()])`, so this
    /// route accepts EITHER — unlike `grain/costs`, which is strictly
    /// `z.number()`. Sent as a number, because that is unambiguous and
    /// `Decimal` encodes as one without going through `Double`.
    ///
    /// `0 < quantity ≤ 1_000_000` and `0 ≤ price ≤ 10_000_000`.
    let quantityTonnes: Decimal
    let pricePerTonne: Decimal?

    /// A `z.literal('EUR')`, NOT an enum. The exchange is single-currency
    /// by design — it used to accept BGN and USD and was deliberately
    /// narrowed, so BGN is a 400 rather than a conversion. There is no
    /// picker for this, because there is no choice.
    let priceCurrency = "EUR"

    let regionCode: String
    let description: String?
    let sellerDisplayName: String?

    /// PRIVATE. Never projected into a public listing — it is revealed to
    /// exactly one buyer, and only if the seller accepts their inquiry.
    /// Sent on create, never rendered on a listing card, because the
    /// server keeping it private does not stop a client implying it is
    /// public.
    let sellerContact: String?

    /// Must be in the FUTURE when present, or the schema refuses it.
    let expiresAt: String?

    enum Invalid: Equatable {
        case quantityOutOfRange
        case priceOutOfRange
        case regionMissing
        case expiryInThePast
    }

    static let maxQuantity = Decimal(1_000_000)
    static let maxPrice = Decimal(10_000_000)

    /// The server's bounds, mirrored so an operator learns before the
    /// request rather than after — and this write in particular must not
    /// be attempted twice.
    var problems: [Invalid] {
        var found: [Invalid] = []
        if quantityTonnes <= 0 || quantityTonnes > Self.maxQuantity {
            found.append(.quantityOutOfRange)
        }
        if let pricePerTonne, pricePerTonne < 0 || pricePerTonne > Self.maxPrice {
            found.append(.priceOutOfRange)
        }
        if regionCode.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(.regionMissing)
        }
        return found
    }
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
        Self.escape(value)
    }

    /// The same escaping, for callers with no query to hand — the messaging
    /// cursors, which travel in a query string exactly as the board's do.
    static func escape(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URLEscape.queryValue(trimmed)
    }
}
