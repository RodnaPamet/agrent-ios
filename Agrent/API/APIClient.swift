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

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    enum APIError: LocalizedError {
        case notSignedIn
        case conflict           // 409 — someone else edited it first
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not signed in."
            case .conflict: "This entry changed on the server while you were editing it."
            case .http(let code, let body): "Server error \(code): \(body)"
            }
        }
    }

    func get<T: Decodable>(_ path: String, as _: T.Type) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil, idempotencyKey: nil)
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
        path: String, method: String, body: Data?, idempotencyKey: String?
    ) async throws -> Data {
        var tokens = try currentTokens()
        if tokens.isExpired { tokens = try await refresh(tokens) }

        var (data, http) = try await perform(path, method, body, idempotencyKey, tokens)
        if http.statusCode == 401 {
            tokens = try await refresh(tokens)
            (data, http) = try await perform(path, method, body, idempotencyKey, tokens)
        }

        switch http.statusCode {
        case 200..<300: return data
        case 409: throw APIError.conflict
        default: throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func perform(
        _ path: String, _ method: String, _ body: Data?, _ key: String?, _ tokens: Tokens
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: Config.baseURL.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
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
            var req = URLRequest(url: Config.baseURL.appending(path: "/api/auth/token/refresh"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["refreshToken": current.refreshToken])

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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
