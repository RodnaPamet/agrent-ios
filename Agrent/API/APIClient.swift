import Foundation

/// One place that knows about bearer tokens, refresh and idempotency.
///
/// TWO THINGS THIS DOES THAT A NAIVE CLIENT WOULD NOT:
///
/// 1. Refresh ONCE on a 401, then retry. Without the single-flight guard a
///    screen firing three requests at once refreshes three times and races.
/// 2. Send `Idempotency-Key` on every create. The server dedupes on it
///    (`LogEntry.clientMutationId`, unique per tenant), so a request whose
///    RESPONSE was lost — the ordinary case on a tractor — replays without
///    writing a second entry. A regulatory diary must not double-record.
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
        /// write was refused. Both web drains currently mistake it for a
        /// terminal payload rejection and park the whole queue (#938, open).
        case clientTooOld
        /// 304 Not Modified — the server confirms the cached copy is current.
        ///
        /// Normally unreachable: URLSession revalidates its own HTTP cache and
        /// hands the caller the stored 200 before this switch sees anything.
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
        case http(status: Int, code: String?, message: String?)

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
            case .http(let status, let code, _):
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

            init(code: String?, message: String?, details: Details?) {
                self.code = code
                self.message = message
                self.details = details
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
                }
                let object = try container.decode(Object.self)
                self.init(code: object.code, message: object.message, details: object.details)
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
            idempotencyKey: idempotencyKey, ifMatch: String(version)
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
    /// omission: the grain routes ignore the header entirely, and sending
    /// one that is ignored would read, to the next person, as protection
    /// that is not there.
    func postReturningData<B: Encodable>(
        _ path: String, body: B, idempotencyKey: String?
    ) async throws -> Data {
        let payload = try encoder.encode(body)
        return try await send(
            path: path, method: "POST", body: payload, idempotencyKey: idempotencyKey
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

    // MARK: - internals

    private func send(
        path: String, method: String, body: Data?, idempotencyKey: String?,
        ifMatch: String? = nil
    ) async throws -> Data {
        var tokens = try currentTokens()
        if tokens.isExpired { tokens = try await refresh(tokens) }

        var (data, http) = try await perform(path, method, body, idempotencyKey, ifMatch, tokens)
        if http.statusCode == 401 {
            tokens = try await refresh(tokens)
            (data, http) = try await perform(path, method, body, idempotencyKey, ifMatch, tokens)
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 409:
            let env = Self.envelope(from: data)
            throw APIError.conflict(
                currentVersion: env?.details?.currentVersion,
                expectedVersion: env?.details?.expectedVersion
            )
        case 304:
            throw APIError.notModified
        case 426:
            throw APIError.clientTooOld
        default:
            let env = Self.envelope(from: data)
            throw APIError.http(
                status: http.statusCode, code: env?.code, message: env?.message
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
    /// The query is taken VERBATIM, so a caller interpolating a value into it
    /// owns percent-encoding that value.
    private static func url(for pathAndQuery: String) throws -> URL {
        guard var comps = URLComponents(url: Config.baseURL, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        comps.path = String(parts[0])
        comps.percentEncodedQuery = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    private func perform(
        _ path: String, _ method: String, _ body: Data?, _ key: String?,
        _ ifMatch: String?, _ tokens: Tokens
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: try Self.url(for: path))
        req.httpMethod = method
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }

        let loggable = LoggablePath(path)
        Log.request(method, loggable)
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
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
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["refreshToken": seen.refreshToken])

            let (data, response) = try await URLSession.shared.data(for: req)
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
                Log.auth.error(
                    "token refresh rejected (\(status, privacy: .public) \(code ?? "no code", privacy: .public)), clearing tokens"
                )
                TokenStore.clear()
                throw APIError.notSignedIn
            }
            struct R: Decodable { let accessToken: String; let refreshToken: String; let expiresIn: Int }
            let r = try JSONDecoder().decode(R.self, from: data)
            let fresh = Tokens(
                accessToken: r.accessToken,
                refreshToken: r.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(r.expiresIn))
            )
            TokenStore.save(fresh)
            return fresh
        }
        refreshTask = task
        return try await task.value
    }
}
