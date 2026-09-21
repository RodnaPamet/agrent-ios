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
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Not signed in."
            case .conflict:
                "Записът е променен на сървъра, докато го редактирахте."
            case .clientTooOld:
                "Тази версия на приложението е твърде стара. Обновете я."
            case .http(let code, let body):
                body.isEmpty ? "Server error \(code)." : "Server error \(code): \(body)"
            }
        }
    }

    /// The 409 body is NESTED: { error: { code, message, details: { … } } }.
    /// Reading `currentVersion` off the top level silently yields nil, and a
    /// keep-mine retry then sends no If-Match at all. The web client did
    /// exactly that for months (#922).
    private struct ConflictEnvelope: Decodable {
        struct Err: Decodable {
            struct Details: Decodable {
                let currentVersion: Int?
                let expectedVersion: Int?
            }
            let code: String?
            let details: Details?
        }
        let error: Err?
    }

    func get<T: Decodable>(_ path: String, as _: T.Type) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil, idempotencyKey: nil)
        return try decoder.decode(T.self, from: data)
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
            let env = try? decoder.decode(ConflictEnvelope.self, from: data)
            throw APIError.conflict(
                currentVersion: env?.error?.details?.currentVersion,
                expectedVersion: env?.error?.details?.expectedVersion
            )
        case 426:
            throw APIError.clientTooOld
        default:
            throw APIError.http(http.statusCode, Self.readableBody(data, http))
        }
    }

    /// A body a HUMAN can read, or none at all.
    ///
    /// Measured 2026-09-21: a 404 returned Next.js's 102,151-byte HTML error
    /// page. `.http` interpolated it whole into `errorDescription`, which
    /// `JournalListView` handed to a SwiftUI `Text`. The layout blew up — the
    /// user saw NO readable message and the "Опитай пак" button was pushed off
    /// screen, so the failure was illegible AND inescapable. The error had to be
    /// read off the network log instead.
    ///
    /// Any HTML error page does this — a 500, a proxy page, a Cloudflare block —
    /// so it is bounded here, once, rather than at each call site.
    private static func readableBody(_ data: Data, _ http: HTTPURLResponse) -> String {
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("json") else { return "" }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.count <= 300 ? text : String(text.prefix(300)) + "…"
    }

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

    /// Single-flight: concurrent callers await the same refresh.
    private func refresh(_ current: Tokens) async throws -> Tokens {
        if let inflight = refreshTask { return try await inflight.value }
        let task = Task<Tokens, Error> {
            defer { refreshTask = nil }
            Log.auth.info("token refresh starting")
            var req = URLRequest(url: Config.baseURL.appending(path: "/api/auth/token/refresh"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["refreshToken": current.refreshToken])

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.auth.error("token refresh rejected, clearing tokens")
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
