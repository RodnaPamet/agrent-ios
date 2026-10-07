import Foundation

/// One place that knows about bearer tokens, refresh and idempotency.
///
/// TWO THINGS THIS DOES THAT A NAIVE CLIENT WOULD NOT:
///
/// 1. Refresh ONCE on a 401, then retry. Without the single-flight guard a
///    screen firing three requests at once refreshes three times and races.
/// 2. Carry the CALLER's `Idempotency-Key`. Where a route honours one the
///    server dedupes on it (`clientMutationId`, unique per tenant), so a
///    request whose RESPONSE was lost — the ordinary case on a tractor —
///    replays without writing a second row. A regulatory diary must not
///    double-record.
///
///    It used to say "on every create", which was never true: honouring is
///    per ROUTE (ROADMAP.md, "Writes: the rule is per-usecase"). The ones
///    that pass a key kept across retries today: journal create, field
///    operation (the outbox replays with the operation's own id), task
///    status, the grain cost create, the insurance lead, and the exchange
///    message send (#114, from `MessageSendKeys`). `post` still DEFAULTS to
///    a fresh key per call, which protects nothing — a caller that needs
///    dedupe must pass its own.
actor APIClient {
    static let shared = APIClient()

    private var refreshTask: Task<Tokens, Error>?

    /// Prisma serialises through Next as `2026-09-12T10:00:00.000Z` — ISO 8601
    /// WITH fractional seconds. Foundation's `.iso8601` strategy rejects those
    /// outright, so every entry fails to decode and the list comes back empty
    /// with a decoding error rather than anything that names the cause. Accept
    /// both spellings.
    private let decoder: JSONDecoder = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not an ISO 8601 date: \(text)"
            ))
        }
        return d
    }()
    /// NOT `URLSession.shared`, and the difference is a minute of spinner.
    ///
    /// ── Measured on a real phone, in a field's worth of signal ──
    ///
    /// The shared session's `timeoutIntervalForRequest` is 60 seconds. Put
    /// an iPhone into airplane mode and iOS commonly leaves Wi-Fi ON — so
    /// the device still has a link to a router and believes it has
    /// connectivity. The request does not fail fast; it waits the full
    /// sixty seconds before `CachedResource` is ever allowed to fall back.
    ///
    /// The owner saw exactly this: Локации stuck on a loading spinner
    /// after turning airplane mode on, having loaded instantly from cache
    /// moments earlier. Nothing was broken — the cache was populated and
    /// correct. The app simply refused to look at it for a minute.
    ///
    /// ── Why fifteen ──
    ///
    /// Long enough for a 17 KB payload over a poor rural connection, and
    /// short enough that a farmer holding a phone concludes "no signal"
    /// rather than "broken app". A spinner that resolves in fifteen
    /// seconds is a slow network; one that resolves in sixty is neither
    /// believed nor waited for.
    ///
    /// `waitsForConnectivity` is false by default for a non-background
    /// session and is set explicitly, because the failure it produces when
    /// true — waiting indefinitely rather than erroring — is precisely the
    /// behaviour this file exists to avoid.
    ///
    /// ── And no URL cache (#134) ──
    ///
    /// Built from `NoURLCache.configuration()`, so `urlCache` is nil: no
    /// response this session receives — the staff directory and ЕГН/ЕИК/УРН
    /// included — reaches Cache.db. `ResponseCache` is the app's only disk
    /// cache. A static function rather than an inline closure so
    /// `NoURLCacheTests` can assert on the configuration itself.
    private let session = URLSession(configuration: APIClient.sessionConfiguration())

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = NoURLCache.configuration()
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        #if DEBUG
        // THE UI TEST SEAM, and the only place in the networking layer that
        // knows it exists.
        //
        // `URLProtocol.registerClass` is the usual incantation and does NOT
        // work here: it registers into the global list that `URLSession.shared`
        // consults, and this session is built from its own configuration, which
        // carries its own `protocolClasses`. It would not catch
        // `AuthClient.exchange` either, which since #134 uses
        // `NoURLCache.session` — and that path is unreachable under the seam
        // anyway, because the app never shows the sign-in screen that starts it.
        //
        // PREPENDED rather than replacing the list: the default protocols still
        // handle anything `FixtureURLProtocol.canInit` declines, and `canInit`
        // re-reads `UITestSeam.isActive` so the ordering cannot matter on a
        // normal run. On a normal run this `if` is false and the configuration
        // is byte-for-byte what it has always been.
        if UITestSeam.isActive {
            configuration.protocolClasses =
                [FixtureURLProtocol.self] + (configuration.protocolClasses ?? [])
        }
        #endif
        return configuration
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    enum APIError: LocalizedError {
        case notSignedIn
        /// 409 STALE_DATA. `currentVersion` is what the server holds now —
        /// resend with `If-Match: currentVersion` to take-server, or show the
        /// operator both. NEVER treat this as a save: the web modal closed
        /// like a success on 409 and parked the write where nothing could
        /// resolve it (#921/#922).
        case conflict(currentVersion: Int?, expectedVersion: Int?)
        /// 426 from middleware means THIS CLIENT IS TOO OLD, not that the
        /// write was refused. Both web drains used to mistake it for a
        /// terminal payload rejection and park the whole queue; they now keep
        /// every item untouched and stop (agri-saas#938). So does this app's
        /// outbox, which also stops asking for the rest of the process
        /// (`OutboxStore.isClientTooOld`, agrent-ios#168).
        ///
        /// The gate reads `x-agrent-client-version`, which this app declares
        /// on every request since #169 (`ClientHeader.contractVersion`). It
        /// is 1, and so is the server's floor, so nothing answers this app
        /// with a 426 yet: the day the floor passes this build's contract,
        /// every gated route does. The spray sheet then keeps a record for
        /// the updated app (`ParcelOperationSheet.QueueOffer`, #169).
        case clientTooOld
        /// 304 Not Modified — the server confirms the cached copy is current.
        ///
        /// Unreachable today: the app sends no `If-None-Match` of its own, and
        /// since #134 URLSession has no HTTP cache to revalidate from, so
        /// nothing asks the server for a 304. Kept because a proxy or a
        /// future conditional request could still produce one.
        /// But `default:` used to catch it and render "Грешка от сървъра
        /// (304)" on a screen whose data is perfectly fine, so the one path
        /// where it CAN surface produced an error for a success.
        case notModified
        /// An HTTP failure, with the envelope already taken apart.
        ///
        /// It used to be `http(Int, String)` where the String was up to 300
        /// characters of RAW JSON, interpolated whole into the sentence an
        /// operator reads:
        ///
        ///     Грешка от сървъра (404): {"error":{"code":"NOT_FOUND",
        ///     "message":"Access review not found"}}
        ///
        /// Braces, quotes, an English sentence and a Bulgarian prefix, on a
        /// screen where the only actionable thing is whether to try again.
        /// The server's own `code` was sitting inside that string, already
        /// decodable, already the thing worth having.
        /// `params` carries the refusal's own values — the product that
        /// was rejected, the fields that were missing. Optional with a
        /// default so every existing construction still compiles and only
        /// the routes that send them have to care.
        ///
        /// `retryAfterSeconds` is the server's `Retry-After`, read off the
        /// HEADER of a 429 or a 503 by `retryAfterSeconds(for:)` and nil
        /// everywhere else. CARRIED, NOT ACTED ON: blocking a request inside
        /// the networking layer for up to an hour is the caller's decision,
        /// and the rule for what a wait means lives in `RateLimitGate`.
        ///
        /// ── A fifth value, not a `.rateLimited` case ──
        ///
        /// A new case would make every `.http(let status …)` match in the
        /// app silently stop seeing 429s. `PendingOperations.isWorthRetrying`
        /// reads `status == 429` as "try later"; behind a new case it would
        /// call a rate-limited spray REFUSED. That is the guard that cannot
        /// fire, which this repo has already paid for twice — `.http(409)`
        /// matched against a client that only ever threw `.conflict`.
        ///
        /// Defaulted for the reason `params` gives, so constructions compile
        /// unchanged. Four-element PATTERNS do not, and that is wanted: the
        /// one site that would have compiled is a rebuild that omits the
        /// label, `SpatialImportAPI.humanised`, and a test holds it.
        case http(status: Int, code: String?, message: String?,
                  params: [String: String]? = nil,
                  retryAfterSeconds: Int? = nil)

        /// The wait the server asked for, whichever case this is.
        var retryAfterSeconds: Int? {
            if case .http(_, _, _, _, let seconds) = self { return seconds }
            return nil
        }

        /// DELIBERATELY NOT the operator-facing text.
        ///
        /// `LocalizedError` is Foundation's channel and it has no idea which
        /// codes this app can name in Bulgarian. `UserMessage.text(for:)` is
        /// the one that decides what a person sees; this stays a developer
        /// description so the two cannot silently diverge, and so nothing
        /// reaches a screen by accidentally reading `localizedDescription`.
        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Не сте влезли в профила си."
            case .conflict:
                "Записът е променен на сървъра, докато го редактирахте."
            case .clientTooOld:
                "Тази версия на приложението е твърде стара. Обновете я."
            case .notModified:
                "Данните не са променени."
            case .http(let status, let code, _, _, _):
                code.map { "HTTP \(status) \($0)" } ?? "HTTP \(status)"
            }
        }
    }

    /// The 409 body is NESTED: { error: { code, message, details: { … } } }.
    /// Reading `currentVersion` off the top level silently yields nil, and a
    /// keep-mine retry then sends no If-Match at all. The web client did
    /// exactly that for months (#922).
    struct ErrorEnvelope: Decodable {
        struct Err: Decodable {
            struct Details: Decodable {
                let currentVersion: Int?
                let expectedVersion: Int?
            }
            let code: String?
            let message: String?
            let details: Details?

            /// The refusal's own values, for building a sentence about
            /// THIS failure rather than about its category.
            ///
            /// Decoded as strings only. The server sends them as strings
            /// (`params.max` is `"12"`, not `12`), and a loose `[String: Any]`
            /// would put decoding of an arbitrary JSON value on the error
            /// path — which is how a 404 became a blank screen once
            /// already.
            let params: [String: String]?

            init(code: String?, message: String?, details: Details?,
                 params: [String: String]? = nil) {
                self.code = code
                self.message = message
                self.details = details
                self.params = params
            }

            /// TWO SHAPES under the same key, and the diagnostic that found
            /// it was the one added to chase the sign-out bug:
            ///
            ///     tenant API  {"error": {"code": "...", "message": "..."}}
            ///     auth API    {"error": "invalid_grant"}
            ///
            /// The auth routes put a bare STRING where everything else puts
            /// an object. Decoding only the object form made the refresh
            /// failure log `(401 no code)` — which read as "the server sent
            /// no code" when the server had sent one, in the other shape.
            /// A diagnostic that under-reports is worse than none, because
            /// it is believed.
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self.init(code: text, message: nil, details: nil)
                    return
                }
                struct Object: Decodable {
                    let code: String?
                    let message: String?
                    let details: Details?
                    let params: [String: String]?
                }
                let object = try container.decode(Object.self)
                self.init(code: object.code, message: object.message,
                          details: object.details, params: object.params)
            }
        }
        let error: Err?
    }

    /// Read the envelope off ANY failing status, not just 409.
    ///
    /// The 409 path has parsed this shape against real responses since the
    /// optimistic-locking work, so the structure is proven rather than
    /// guessed — it was simply never used anywhere else, and every other
    /// status fell back to printing the bytes.
    ///
    /// Returns nil rather than throwing: an error path that can itself fail
    /// is how a 404 became a blank screen once already. A server that
    /// answers a failure with an HTML page is the ordinary case, not an
    /// exceptional one.
    static func envelope(from data: Data) -> ErrorEnvelope.Err? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
    }

    /// What a 409 becomes. Out of `send` so the mapping is a unit test: there
    /// is no URLProtocol seam in `Tests/`, and "the versions come from
    /// `error.details`, not the body root" is exactly the rule that silently
    /// broke on the web (#922).
    static func conflict(from data: Data) -> APIError {
        let env = envelope(from: data)
        return .conflict(
            currentVersion: env?.details?.currentVersion,
            expectedVersion: env?.details?.expectedVersion
        )
    }

    /// The `If-Match` value for a version: the BARE integer, `5`.
    ///
    /// One spelling for every locked route. Until agri-saas#1182 the journal
    /// and field-operations routes read only this and fell through to "no
    /// precondition" on anything else, a quoted tag included, while the farm
    /// profile took a strong tag (`"5"`) and refused a weak one (`W/"5"`).
    /// Since #1255 (2026-10-02) all three share one strict parser
    /// (`src/lib/http/if-match.ts`): bare and strong both read as 5, and a
    /// weak, empty or malformed header is a 400 `IF_MATCH_*` rather than a
    /// silent fall-through. The bare integer stays the spelling here — it is
    /// what both clients' outboxes send, the house convention the parser
    /// documents, and the one form every server version reads the same way.
    static func ifMatch(_ version: Int) -> String { String(version) }

    // MARK: - Retry-After

    /// The longest wait this client will honour, in seconds.
    ///
    /// An hour: the longest window or lockout among the server's presets
    /// that this app can reach — `FarmRiskAPI.createLead` draws on an hourly
    /// budget. A server asking for more than that is misconfigured, and
    /// honouring it would park a farmer's field records for a day. At worst
    /// the app asks again after an hour, is told to wait again, and does.
    static let retryAfterCeiling = 3600

    /// `Retry-After` off a 429 or a 503, in whole seconds — nil for any other
    /// status, for a missing header, and for one this cannot read.
    ///
    /// ── The HEADER, never the body ──
    ///
    /// The middleware's 429 also puts `retryAfterSeconds` in the envelope, and
    /// it is a NUMBER. A typed field on `ErrorEnvelope`'s object that ever
    /// arrived mistyped would fail the whole decode and lose `code` and
    /// `message` with it — the error path failing, which is how a 404 became
    /// a blank screen once already. The header is the contract (RFC 9110,
    /// and the spec's own 429 description); the body is an echo of it.
    ///
    /// ── Only 429 and 503 ──
    ///
    /// The statuses the header means something on, and the same pair the
    /// web's `parseRetryAfterSeconds` reads. A 503's wait is carried
    /// truthfully and then ignored by the outbox — see `RateLimitGate`.
    ///
    /// `value(forHTTPHeaderField:)` is case-insensitive, so the lowercase
    /// `retry-after` an HTTP/2 response carries is found too. Tested rather
    /// than assumed.
    static func retryAfterSeconds(for response: HTTPURLResponse, now: Date = Date()) -> Int? {
        guard response.statusCode == 429 || response.statusCode == 503 else { return nil }
        return retryAfterSeconds(
            header: response.value(forHTTPHeaderField: "Retry-After"),
            responseDate: response.value(forHTTPHeaderField: "Date"),
            now: now
        )
    }

    /// The parse itself, PURE — every input passed in, so a test can hold the
    /// server's clock and the device's apart.
    ///
    /// Two forms, per RFC 9110:
    ///
    ///     Retry-After: 12                              delay-seconds
    ///     Retry-After: Tue, 29 Sep 2026 10:01:30 GMT   IMF-fixdate
    ///
    /// This server only ever sends the first, and at least 1 — except the
    /// auth limiter, which does not clamp and can send "0". "0" is carried as
    /// 0; flooring it is policy, and policy is `RateLimitGate`'s.
    ///
    /// DELAY-SECONDS IS DIGITS AND NOTHING ELSE. "-1", "1.5" and "12abc" are
    /// not delay-seconds and read as nil, which is stricter than the web's
    /// `parseInt` (that takes "12abc" as 12). A value too long for `Int` makes
    /// `Int(_:)` answer nil rather than trap, and anything that long is
    /// certainly past the ceiling, so it reads as the ceiling.
    ///
    /// AN HTTP-DATE IS MEASURED AGAINST THE RESPONSE'S OWN `Date`, not the
    /// phone's clock. The two moments come from one clock, so the difference
    /// is the wait the server meant whatever the device thinks the time is —
    /// with the phone ten minutes fast, the device clock would have read a
    /// 90-second wait as none at all. The device clock is the fallback for a
    /// response with no `Date`. The obsolete RFC 850 and asctime forms read
    /// as nil, and a caller then waits its own default.
    static func retryAfterSeconds(header: String?, responseDate: String?, now: Date) -> Int? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return nil }

        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        if text.utf8.allSatisfy({ digits.contains($0) }) {
            guard let seconds = Int(text) else { return retryAfterCeiling }
            return min(seconds, retryAfterCeiling)
        }

        guard let moment = imfFixdate(text) else { return nil }
        let base = responseDate.flatMap { imfFixdate($0) } ?? now
        let delta = moment.timeIntervalSince(base).rounded(.up)
        // Clamped as a Double, BEFORE the conversion: `Int(_:)` traps on a
        // value out of range, and a date is exactly where one comes from.
        guard delta.isFinite else { return nil }
        return Int(min(max(delta, 0), Double(retryAfterCeiling)))
    }

    /// `Tue, 29 Sep 2026 10:01:30 GMT` and only that.
    ///
    /// A formatter per call, not a shared one: this path runs roughly never,
    /// and a `DateFormatter` is a mutable object that would be shared between
    /// this actor and every test that calls the parser. `en_US_POSIX` so the
    /// day and month names are read as the protocol spells them whatever the
    /// device's language, and a Gregorian calendar so a phone set to another
    /// one does not read 2026 as a different year.
    private static func imfFixdate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    func get<T: Decodable>(_ path: String, as _: T.Type) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil, idempotencyKey: nil)
        return try decoder.decode(T.self, from: data)
    }

    /// The raw bytes of a GET, for callers that cache the payload before
    /// deciding how to read it. `ResponseCache` stores `Data` rather than
    /// decoded models on purpose — see its header.
    func data(for path: String) async throws -> Data {
        try await send(path: path, method: "GET", body: nil, idempotencyKey: nil)
    }

    /// Decode with THIS client's decoder — the one that accepts ISO 8601 both
    /// with and without fractional seconds. A caller reaching for a fresh
    /// `JSONDecoder()` reintroduces the bug documented above it.
    func decode<T: Decodable>(_ data: Data, as _: T.Type) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    /// EDITS (when they land) MUST send `If-Match: <version>` — digits only.
    /// The version increment sits INSIDE the If-Match guard on the server, so
    /// an unguarded PATCH changes content WITHOUT moving version, and every
    /// later optimistic lock is then wrong. Treat If-Match as mandatory, not
    /// as an optimisation.
    func patch<B: Encodable, T: Decodable>(
        _ path: String, body: B, ifMatch version: Int, as _: T.Type,
        idempotencyKey: String
    ) async throws -> T {
        let payload = try encoder.encode(body)
        let data = try await send(
            path: path, method: "PATCH", body: payload,
            idempotencyKey: idempotencyKey, ifMatch: Self.ifMatch(version)
        )
        return try decoder.decode(T.self, from: data)
    }

    /// A POST whose RAW response the caller decodes itself.
    ///
    /// For routes whose response shape is not yet known. `POST
    /// /tasks/:id/status` returns the whole task row with no relations,
    /// which is a third shape on that model — not the list's projection and
    /// not the detail's expansion. Handing back bytes lets a caller probe
    /// before it models, which is the order that has been right every time
    /// today and wrong every time it was reversed.
    /// `idempotencyKey` is OPTIONAL, and nil is a statement rather than an
    /// omission.
    ///
    /// It used to say "the grain routes ignore the header entirely", which is
    /// wrong: `POST /grain/costs` and `POST /grain/yield-records` honour it,
    /// `POST /grain/contracts` does not (traced in agri-saas source
    /// 2026-09-25 — see `CostsAPI.create` for the chain). The rule is
    /// per-ROUTE, not per-area, and a comment that generalises to an area is
    /// how this one came to be wrong twice.
    ///
    /// nil still means something, and it is no longer "the server would
    /// ignore it": it means THIS CALLER HAS NO KEY WORTH SENDING. Two
    /// different reasons, and both are live:
    ///
    ///   - the route reads no header — parcel crop-seasons, weed
    ///     observations, the exchange listing create, admin, and every
    ///     messaging write but the send (open a thread, read, close, block;
    ///     each is idempotent in its domain instead); or
    ///   - it reads one but nothing here would ever send the same value
    ///     twice, so a key would read as protection that is not there.
    ///
    /// The grain cost create left this second group on 2026-09-25 and now
    /// passes a key derived from the draft's content — see
    /// `CostIdempotencyKey` and `CostsAPI.create`. So nil no longer means
    /// "nothing here reuses a key"; one write does.
    func postReturningData<B: Encodable>(
        _ path: String, body: B, idempotencyKey: String?
    ) async throws -> Data {
        let payload = try encoder.encode(body)
        return try await send(
            path: path, method: "POST", body: payload, idempotencyKey: idempotencyKey
        )
    }

    /// A PATCH whose raw response the caller decodes itself, and with no
    /// `If-Match`. The parcel route takes no version — unlike the
    /// journal's PATCH, where the version increment sits INSIDE the
    /// If-Match guard and an unguarded write breaks every later lock.
    /// Asymmetry noted rather than assumed away.
    func patchReturningData<B: Encodable>(_ path: String, body: B) async throws -> Data {
        let payload = try encoder.encode(body)
        return try await send(
            path: path, method: "PATCH", body: payload, idempotencyKey: nil
        )
    }

    func post<B: Encodable, T: Decodable>(
        _ path: String, body: B, as _: T.Type, idempotencyKey: String = UUID().uuidString
    ) async throws -> T {
        let payload = try encoder.encode(body)
        let data = try await send(
            path: path, method: "POST", body: payload, idempotencyKey: idempotencyKey
        )
        return try decoder.decode(T.self, from: data)
    }

    /// PUT, with NO idempotency key.
    ///
    /// The key is for creates, where a retry must not make a second row.
    /// A PUT that replaces a whole value is idempotent by construction —
    /// sending it twice leaves the same state — so a key would be
    /// ceremony. Same reasoning `setTaskStatus` records for comparing
    /// state rather than replaying a request.
    ///
    /// `ifMatch` is OPTIONAL here, unlike `patch`, because the one locked PUT
    /// (`/admin/farm-profile`, agri-saas#1184) documents an absent header as
    /// a supported unguarded write — and the caller only has a version to send
    /// when the server reported one. nil sends no header at all.
    func put<B: Encodable, T: Decodable>(
        _ path: String, body: B, ifMatch version: Int? = nil, as _: T.Type
    ) async throws -> T {
        let payload = try encoder.encode(body)
        let data = try await send(
            path: path, method: "PUT", body: payload, idempotencyKey: nil,
            ifMatch: version.map(Self.ifMatch)
        )
        // A 204 carries no body. `EmptyResponse` decodes nothing, but
        // JSONDecoder still refuses zero bytes, so an empty body becomes
        // an empty object first.
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    /// Encode with THIS client's encoder.
    ///
    /// The outbox needs bytes identical to what a live send would have
    /// produced — same date strategy, same decimal handling. A caller
    /// reaching for a fresh `JSONEncoder()` would queue a payload the
    /// server might read differently from the one it would have received,
    /// which is the same class of bug as `decode` documents one line up.
    func encodeBody<B: Encodable>(_ body: B) throws -> Data {
        try encoder.encode(body)
    }

    /// POST a body that is ALREADY ENCODED.
    ///
    /// For the outbox. A queued operation stores the bytes it was recorded
    /// as, not a model to re-encode — so an app update that renames a
    /// field or changes a default cannot alter what the farmer actually
    /// wrote down before sending it. The recorded intent goes out as
    /// recorded.
    func postRaw(_ path: String, body: Data, idempotencyKey: String) async throws -> Data {
        try await send(path: path, method: "POST", body: body,
                       idempotencyKey: idempotencyKey)
    }

    /// PATCH a body that is ALREADY ENCODED, under the optimistic lock.
    ///
    /// The parcel-line mark (agrent-ios#138), live and replayed: the outbox
    /// stores the bytes the operator's tap produced and the version the line
    /// had when they saw it, and both attempts go out through here so the
    /// two cannot drift apart.
    ///
    /// `version` is NOT optional, unlike `put`'s. The route treats an absent
    /// `If-Match` as "no precondition", so a mark without one is a silent
    /// last-write-wins — the overwrite #138 exists to stop. Making the
    /// unguarded call unspellable is cheaper than remembering not to make it.
    ///
    /// No `Idempotency-Key`: the route reads none, and a replay is already
    /// safe by the lock (`FieldOperationAPI`).
    func patchRaw(_ path: String, body: Data, ifMatch version: Int) async throws -> Data {
        try await send(path: path, method: "PATCH", body: body, idempotencyKey: nil,
                       ifMatch: Self.ifMatch(version))
    }

    /// A DELETE, with its response bytes handed back.
    ///
    /// ── The 404 is NOT swallowed here ──
    ///
    /// A delete whose row is already gone has achieved what the caller
    /// wanted, and several routes want that treated as success. It is still
    /// not this verb's decision: the server's 404 means "not found, OR not
    /// visible to this tenant", and those are the same status with different
    /// meanings. A route where the id came out of a list this client just
    /// fetched can read it as already-deleted; a route where the id was
    /// constructed cannot.
    ///
    /// So the status arrives as `APIError.http(status: 404, …)` like any
    /// other, and the API layer that knows where its ids came from decides —
    /// see `ParcelHistoryAPI.deleteCropSeason`.
    ///
    /// No `Idempotency-Key`: nothing documents the header on a DELETE, and
    /// sending one that is ignored reads as protection that is not there.
    func deleteReturningData(_ path: String) async throws -> Data {
        try await send(path: path, method: "DELETE", body: nil, idempotencyKey: nil)
    }

    /// A `multipart/form-data` POST — the only one in this app.
    ///
    /// ── Why bytes and not a file URL ──
    ///
    /// The caller has already read the file: it has to, because the byte cap
    /// is per-format and is checked BEFORE anything is sent (see
    /// `SpatialImportFormat`). Taking `Data` keeps document-picker scope,
    /// security-scoped URLs and `NSFileCoordinator` out of the networking
    /// layer, where none of them belong.
    ///
    /// ── The boundary ──
    ///
    /// A UUID, so it cannot occur in the payload by accident. A shapefile zip
    /// is arbitrary binary and a boundary collision would truncate the body at
    /// whatever byte happened to match — silently, with a 400 that says
    /// nothing useful. 122 bits of randomness is the cheap way not to think
    /// about it again.
    ///
    /// No `Idempotency-Key`: the import routes document none, and the upload
    /// stages bytes and queues a job rather than writing a row, so a replay
    /// makes a second job rather than a duplicate record.
    func postMultipart(
        _ path: String,
        file: Data,
        fileName: String,
        mimeType: String,
        fields: [String: String] = [:]
    ) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.multipartBody(
            boundary: boundary, file: file, fileName: fileName,
            mimeType: mimeType, fields: fields)

        return try await send(
            path: path, method: "POST", body: body, idempotencyKey: nil,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    /// The body bytes, PURE so the framing can be tested.
    ///
    /// Multipart fails silently when it fails: a missing CRLF or a mis-spelled
    /// disposition gives a 400 that names nothing, and there is no seam in
    /// this suite to observe an outgoing request. Building the bytes in a
    /// function that takes its boundary as an argument makes the one part that
    /// can be wrong checkable without a network.
    ///
    /// TEXT FIELDS FIRST, and sorted. First because the server validates the
    /// extension and the declared size before buffering, so a streaming parser
    /// reaches the cheap fields without waiting for the file. Sorted because
    /// dictionary order is not stable across runs, and a body that differs
    /// between two identical calls is untestable and unreviewable.
    static func multipartBody(
        boundary: String,
        file: Data,
        fileName: String,
        mimeType: String,
        fields: [String: String]
    ) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(file)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: - internals

    /// `contentType` OVERRIDES the `application/json` default.
    ///
    /// Every other body in this app is JSON, so `perform` has always set that
    /// header whenever a body existed. A multipart body must declare its
    /// boundary in the header or the server cannot split the parts at all —
    /// so the one route that is not JSON has to be able to say so.
    private func send(
        path: String, method: String, body: Data?, idempotencyKey: String?,
        ifMatch: String? = nil, contentType: String? = nil
    ) async throws -> Data {
        var tokens = try currentTokens()
        if tokens.isExpired { tokens = try await refresh(tokens) }

        var (data, http) = try await perform(
            path, method, body, idempotencyKey, ifMatch, tokens, contentType)
        if http.statusCode == 401 {
            tokens = try await refresh(tokens)
            (data, http) = try await perform(
                path, method, body, idempotencyKey, ifMatch, tokens, contentType)
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 409:
            throw Self.conflict(from: data)
        case 304:
            throw APIError.notModified
        case 426:
            throw APIError.clientTooOld
        default:
            let env = Self.envelope(from: data)
            // `http` is the FINAL response — after the 401 → refresh → retry
            // above — so the wait read here belongs to the answer being
            // reported, not to the request it replaced.
            throw APIError.http(
                status: http.statusCode, code: env?.code, message: env?.message,
                params: env?.params,
                retryAfterSeconds: Self.retryAfterSeconds(for: http)
            )
        }
    }

    // `readableBody` used to live here. It bounded an error body to 300
    // characters of raw JSON and handed it to the view, which was the right
    // fix for the bug it was written for — a 404 returned Next.js's
    // 102,151-byte HTML error page, the layout blew up, and the "Опитай пак"
    // button was pushed off screen, making the failure illegible AND
    // inescapable.
    //
    // Bounding the blast radius was never the same as reading the message.
    // `envelope(from:)` takes the response apart instead, so a non-JSON body
    // yields nil rather than a truncated fragment of HTML, and the HTML page
    // cannot reach a screen at all — which is a stronger guarantee than a
    // length cap.

    /// Build a request URL from a path that MAY carry a query string.
    ///
    /// NOT `URL.appending(path:)`. That percent-encodes its whole argument, so
    /// `?` becomes `%3F` and "/api/t/agrent/journal?limit=50" turns into a PATH
    /// segment literally named `journal?limit=50`. No route matches it, the
    /// server answers with its 404 HTML page, and `limit` never arrives.
    ///
    /// Measured 2026-09-21: this 404'd every journal load while sign-in worked
    /// perfectly — `AuthClient` builds its URL with `URLComponents` and this did
    /// not. Same codebase, two idioms, one of them wrong.
    ///
    /// The trap that hides it: `url.path` prints the DECODED form and looks
    /// exactly right in a debugger. Only `absoluteString` or `.query` shows the
    /// damage, and `.query` is nil.
    ///
    /// BOTH halves are taken VERBATIM, so a caller interpolating a value into
    /// either owns percent-encoding it — through `URLEscape`, once.
    ///
    /// The path used to go through `comps.path`, the ENCODING setter, while
    /// the query went through the verbatim one. A builder that escaped its id
    /// (as it must, or a `/` in the id is a new segment and a `?` is the split
    /// below) was therefore escaped twice: `par_holes` reached the server as
    /// `par%255Fholes` (agrent-ios#122). `url.path` decodes it back to the
    /// builder's own string, which is why neither the debugger nor the
    /// fixture seam ever showed it. `PathEncodingTests` reads the wire form.
    ///
    /// Validated first because the verbatim setters TRAP on a malformed
    /// string rather than returning nil — see `URLEscape.isPercentEncoded`.
    /// Before this, a raw space in a query was a crash; now it is `badURL`.
    static func url(for pathAndQuery: String) throws -> URL {
        guard var comps = URLComponents(url: Config.baseURL, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        guard URLEscape.isPercentEncoded(path, allowed: .urlPathAllowed),
              query.map({ URLEscape.isPercentEncoded($0, allowed: .urlQueryAllowed) }) ?? true
        else { throw URLError(.badURL) }
        comps.percentEncodedPath = path
        comps.percentEncodedQuery = query
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    /// The request every `APIClient` call starts from: the API host, the
    /// client header and THIS APP'S BEARER. Pure, so a test can see which
    /// requests carry the token — the account card's picture sends it for a
    /// root-relative `avatarUrl` (this path) and never for an absolute one
    /// (`AccountAvatarAPI.externalRequest`, a different host).
    static func request(for path: String, method: String, accessToken: String) throws -> URLRequest {
        var req = URLRequest(url: try url(for: path))
        ClientHeader.stamp(&req)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func perform(
        _ path: String, _ method: String, _ body: Data?, _ key: String?,
        _ ifMatch: String?, _ tokens: Tokens, _ contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var req = try Self.request(for: path, method: method, accessToken: tokens.accessToken)
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/json",
                         forHTTPHeaderField: "Content-Type")
        }
        if let key { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }

        let loggable = LoggablePath(path)
        Log.request(method, loggable)
        let started = Date()
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            Log.response(
                method, loggable, status: http.statusCode, bytes: data.count,
                ms: Int(Date().timeIntervalSince(started) * 1000)
            )
            return (data, http)
        } catch {
            Log.failure(method, loggable, error)
            throw error
        }
    }

    private func currentTokens() throws -> Tokens {
        #if DEBUG
        // THE KEYCHAIN IS NOT TOUCHED UNDER THE SEAM, and that is the whole
        // reason this branch exists rather than a `TokenStore.save` at launch.
        //
        // Planting a token would have been fewer lines and would have written
        // into the Keychain of whatever simulator the seam was pointed at —
        // including, one mistake later, the owner's signed-in one, replacing a
        // real session with a value no server issued. Reading past the
        // Keychain instead leaves it exactly as it was found.
        //
        // The token is never presented to anything: `FixtureURLProtocol`
        // answers before URLSession opens a socket.
        if UITestSeam.isActive { return UITestSeam.stubTokens }
        #endif
        guard let t = TokenStore.load() else { throw APIError.notSignedIn }
        return t
    }

    /// What to do when a caller asks to refresh.
    ///
    /// Pure, and separate from the network, because the rule it encodes is
    /// the whole bug — see `refresh(_:)`.
    enum RefreshDecision: Equatable {
        /// Somebody else already rotated past the token this caller saw.
        /// Their result is in the keychain; use it and send nothing.
        case alreadyRotated(Tokens)
        case perform
        case signedOut
    }

    /// Does this refresh response mean the token is DEAD, or merely that
    /// the server did not answer?
    ///
    /// Pure, and separate, because the distinction is the whole bug: the
    /// old code had no such concept and treated a 502 from a deploying
    /// server exactly like a rejected credential.
    static func invalidatesToken(status: Int) -> Bool { status == 401 }

    /// May a refresh that has just ANSWERED write its outcome to the Keychain?
    ///
    /// Only if the Keychain still holds the pair it started from. A refresh
    /// is a network round trip, and Изход can happen inside it (agri-saas#1191
    /// P0.9). Before this, a refresh that landed after a sign-out SAVED the
    /// departing user's new pair back into an emptied Keychain — the next
    /// launch opened signed in as them — and one refused after a NEW sign-in
    /// cleared the new user's tokens. Pure, so the rule is held by a test
    /// rather than by the timing of one.
    static func mayCommitRefresh(seen: Tokens, stored: Tokens?) -> Bool {
        stored?.refreshToken == seen.refreshToken
    }

    static func refreshDecision(seen: Tokens, stored: Tokens?) -> RefreshDecision {
        guard let stored else { return .signedOut }
        return stored.refreshToken == seen.refreshToken
            ? .perform
            : .alreadyRotated(stored)
    }

    /// Single-flight, and single-flight was NOT enough.
    ///
    /// ── The bug this fixes, measured in production ──
    ///
    /// Refresh tokens rotate and are single-use. Presenting one that has
    /// already been consumed is treated as THEFT: the server burns the whole
    /// rotation lineage and the session, immediately and irreversibly. The
    /// owner was signed out twice in one afternoon, 34 minutes into a
    /// session, and the database recorded both as
    /// `security:refresh-replayed`.
    ///
    /// The app was the thief. Two requests race:
    ///
    ///   1. A and B both go out carrying the same expired access token.
    ///   2. Both come back 401.
    ///   3. A refreshes, rotates, stores the new pair, clears `refreshTask`.
    ///   4. B now calls refresh — and `refreshTask` is already nil, so the
    ///      guard does nothing. B sends the refresh token IT captured in
    ///      step 1, which A consumed 1.02 seconds ago.
    ///
    /// The old guard covered concurrency only while a refresh was IN FLIGHT.
    /// The dangerous window is longer than that: it lasts as long as any
    /// caller is still holding a `Tokens` value it read before the rotation.
    /// A single-flight promise cannot see that, because the second caller
    /// never overlapped the first — it arrived just after.
    ///
    /// So the keychain, not the promise, is the source of truth. If the
    /// stored refresh token is not the one this caller saw, the rotation
    /// already happened and its result is sitting there: take it and send
    /// nothing. The promise still exists, for genuine overlap.
    ///
    /// ── What this does NOT fix ──
    ///
    /// The owner's FIRST sign-out had a 522-second gap, not 1.02, and that
    /// is a different animal: the server rotated and committed, the response
    /// never arrived, and the app kept a token the server had already spent.
    /// From then on the stored token is poisoned and the next refresh —
    /// however well behaved — is indistinguishable from a replay. No client
    /// can fix that alone. The server is adding a bounded grace window that
    /// re-issues the live successor instead of burning the family, which is
    /// the same idea as the `Idempotency-Key` on writes: a lost response
    /// must not be punished as a second attempt.
    private func refresh(_ seen: Tokens) async throws -> Tokens {
        switch Self.refreshDecision(seen: seen, stored: TokenStore.load()) {
        case .signedOut:
            throw APIError.notSignedIn
        case .alreadyRotated(let fresh):
            Log.auth.info("refresh skipped, another caller already rotated")
            return fresh
        case .perform:
            break
        }

        if let inflight = refreshTask { return try await inflight.value }
        let task = Task<Tokens, Error> {
            defer { refreshTask = nil }
            Log.auth.info("token refresh starting")
            var req = URLRequest(url: Config.baseURL.appending(path: "/api/auth/token/refresh"))
            ClientHeader.stamp(&req)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["refreshToken": seen.refreshToken])

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // The status and code are logged, but DO NOT expect them
                // to name the cause, and this correction matters because the
                // commit that added this line claimed they would.
                //
                // The server returns 401 `invalid_grant` for EVERY refresh
                // failure — unparseable body, missing field, unknown token,
                // revoked, expired, replayed — deliberately and identically,
                // so a caller cannot enumerate the difference. Telling a
                // thief that their replay was the thing that was noticed is
                // exactly what that uniformity prevents.
                //
                // So this cannot discriminate, and only the server's own
                // logs can. It is still worth recording: it confirms the
                // response really was 401 rather than a 404 from a moved
                // route or a proxy page, which is a different failure
                // wearing the same words.
                //
                // Both values are safe to persist: a status is a number and a
                // code is a fixed identifier chosen by the server's authors.
                // The body is NOT logged — it is the one response in the app
                // guaranteed to contain tokens.
                let code = Self.envelope(from: data)?.code
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                // ── ONLY A 401 INVALIDATES THE TOKEN ──
                //
                // This used to clear on ANY non-200, and that signed the
                // owner out of a working session. Measured: at 18:18 the
                // refresh returned **502** — the server restarting for a
                // deploy — and the app destroyed a refresh token that was
                // perfectly valid, because a gateway error and a rejected
                // credential took the same branch.
                //
                // It is invisible from the server side too: no session was
                // revoked, so the query that finds replayed-token burns
                // correctly reports zero while the operator is sitting on
                // a sign-in screen. Two true statements, one signed-out
                // farmer.
                //
                // The server returns 401 `invalid_grant` for every genuine
                // refusal — unparseable, expired, revoked, replayed — so a
                // 401 is the whole set of "this token is dead". Anything
                // else means the server did not answer the question, and a
                // question that was not answered is not a no.
                guard status == 401 else {
                    Log.auth.error(
                        "token refresh failed but NOT rejected (\(status, privacy: .public) \(code ?? "no code", privacy: .public)), keeping tokens"
                    )
                    // A CODE, so the sentence can say what happened.
                    //
                    // Without one this threw a bare 400 and `UserMessage`
                    // rendered the generic «Заявката съдържа невалидни данни.»
                    // — on every screen, for a session that could not be
                    // renewed. The owner met it as "the satellite data does
                    // not render", which is what it looks like from the
                    // outside: the request that failed is invisible and the
                    // sentence blames the data.
                    //
                    // Keeping the tokens is still right — see above, a
                    // question that was not answered is not a no — and the
                    // episode that prompted this PROVED the rule rather than
                    // breaking it. The 400 came from a different application
                    // answering on the same hostname, not from this server;
                    // clearing tokens on it would have signed a farmer out
                    // because of a proxy. The premise above was true of the
                    // server and false only of what reached us.
                    //
                    // What was wrong was saying nothing true about it. Silence
                    // plus a generic sentence blaming the DATA is the worst of
                    // both, so the failure now names itself.
                    //
                    // AND IT CARRIES ITS WAIT. The token refresh is the auth
                    // limiter's 10-a-minute tier, and its 429 surfaces from
                    // `send` as the failure of the request that needed the
                    // refresh — so the outbox pauses on it as it would on the
                    // route's own 429. Right, not incidental: the next attempt
                    // needs a refresh too. That limiter does not clamp, so "0"
                    // is a real answer here and the floor is `RateLimitGate`'s.
                    //
                    // AND A 429 IS NOT GIVEN THE INVENTED CODE. A code is
                    // looked up before `UserMessage`'s 429 rule, and this one
                    // says «Излезте от менюто и влезте отново» — advice that
                    // signs a farmer out, and signing back in goes through the
                    // same auth limiter that just refused. The limiter's own
                    // body carries `RATE_LIMITED`; only a 429 with no code — a
                    // proxy's, or the other application on this hostname —
                    // reached this, and without a code it now says what every
                    // other 429 says.
                    throw APIError.http(status: status,
                                        code: code ?? (status == 429 ? nil : "TOKEN_REFRESH_FAILED"),
                                        message: nil,
                                        retryAfterSeconds: (response as? HTTPURLResponse)
                                            .flatMap { Self.retryAfterSeconds(for: $0) })
                }

                Log.auth.error(
                    "token refresh rejected (\(status, privacy: .public) \(code ?? "no code", privacy: .public)), clearing tokens"
                )
                // Only the pair this refresh was FOR. If the Keychain moved on
                // meanwhile — Изход, or somebody else signed in — the dead token
                // is not the one stored, and clearing would sign out the wrong
                // session.
                if Self.mayCommitRefresh(seen: seen, stored: TokenStore.load()) {
                    TokenStore.clear()
                }
                throw APIError.notSignedIn
            }
            struct R: Decodable { let accessToken: String; let refreshToken: String; let expiresIn: Int }
            let r = try JSONDecoder().decode(R.self, from: data)
            let fresh = Tokens(
                accessToken: r.accessToken,
                refreshToken: r.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(r.expiresIn))
            )
            // NOT saved if the session ended while this was in flight: that
            // would resurrect a signed-out user's tokens. The pair is still
            // returned to this caller, whose request was made under it.
            if Self.mayCommitRefresh(seen: seen, stored: TokenStore.load()) {
                TokenStore.save(fresh)
            } else {
                Log.auth.info("refresh answered after the session changed, not saved")
            }
            return fresh
        }
        refreshTask = task
        return try await task.value
    }
}
