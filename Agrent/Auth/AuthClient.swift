import AuthenticationServices
import Foundation
import Observation

/// Sign-in runs in the SYSTEM browser, not a WKWebView.
///
/// That is not a style choice: Google refuses OAuth inside an embedded webview
/// (`disallowed_useragent`). `ASWebAuthenticationSession` is the supported
/// surface and gives us the shared Safari cookie jar, so a user already signed
/// in on the web is one tap away.
@Observable
@MainActor
final class AuthClient: NSObject {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case failed(String)
    }

    private(set) var state: State = .signedOut
    private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
        if TokenStore.load() != nil { state = .signedIn }
    }

    func signIn() async {
        state = .signingIn
        Log.auth.info("sign-in started")
        let pkce = PKCE()

        var comps = URLComponents(
            url: Config.baseURL.appending(path: "/api/auth/native/start"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "provider", value: "google"),
        ]

        do {
            let callback = try await present(url: comps.url!)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                state = .failed("The sign-in came back without a code.")
                Log.auth.error("callback carried no code")
                return
            }
            try await exchange(code: code, verifier: pkce.verifier)
            state = .signedIn
            Log.auth.info("sign-in complete")
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            state = .signedOut
            Log.auth.info("sign-in cancelled by user")
        } catch {
            state = .failed(friendly(error))
            Log.auth.error("sign-in failed: \(Log.summary(for: error), privacy: .public)")
        }
    }

    func signOut() {
        TokenStore.clear()
        // The cached identity is per-session. Leaving it would let the
        // next person to sign in on this device be assigned somebody
        // else's operations.
        CurrentUserStore.shared.clear()
        state = .signedOut
    }

    // MARK: - internals

    private func present(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Config.redirectScheme
            ) { callbackURL, error in
                if let error { cont.resume(throwing: error) }
                else if let callbackURL { cont.resume(returning: callbackURL) }
                else { cont.resume(throwing: URLError(.badServerResponse)) }
            }
            s.presentationContextProvider = self
            // Use the shared cookie jar: if they are signed in to app.agrent.bg
            // in Safari, this becomes a single tap rather than a full login.
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            s.start()
        }
    }

    private func exchange(code: String, verifier: String) async throws {
        var req = URLRequest(url: Config.baseURL.appending(path: "/api/auth/native/exchange"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "code_verifier": verifier])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        Log.auth.info("native exchange → \(status, privacy: .public)")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.server(String(data: data, encoding: .utf8) ?? "exchange failed")
        }
        let payload = try JSONDecoder().decode(ExchangeResponse.self, from: data)
        TokenStore.save(Tokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        ))
    }

    private func friendly(_ error: Error) -> String {
        let text = (error as? AuthError).map(\.message) ?? error.localizedDescription
        // The one failure worth naming precisely, because it is configuration
        // rather than a bug and the raw message does not say so.
        if text.contains("redirect_uri_not_allowed") {
            return """
            The server refused this app's callback URL. Add
            \(Config.redirectURI) to NATIVE_AUTH_REDIRECT_ALLOWLIST on the \
            server and restart it. See README.
            """
        }
        return text
    }

    private struct ExchangeResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }
}

enum AuthError: Error {
    case server(String)
    var message: String { if case .server(let m) = self { return m }; return "" }
}

extension AuthClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
