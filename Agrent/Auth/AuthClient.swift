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
                state = .failed("Входът приключи без код за достъп.")
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
        guard status == 200 else {
            // The envelope, not the body. This used to throw the raw
            // response text, which `friendly` then returned verbatim — so a
            // failed token exchange printed JSON onto the sign-in screen,
            // the exact defect `APIError.http` was restructured to remove
            // and the one screen that had not been restructured with it.
            let env = APIClient.envelope(from: data)
            throw AuthError.server(status: status, code: env?.code, message: env?.message)
        }
        let payload = try JSONDecoder().decode(ExchangeResponse.self, from: data)
        TokenStore.save(Tokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        ))
    }

    /// Through `UserMessage`, like every other screen.
    ///
    /// This read `error.localizedDescription` as its fallback, which is
    /// precisely what `UserMessage`'s own header documents as the bug: the
    /// device reports en-BG, so a `URLError` rendered
    /// "Could not connect to the server." under a Bulgarian heading. Sign-in
    /// is the FIRST screen a farmer sees and the one most likely to fail —
    /// no signal, wrong configuration — so it was the worst place left
    /// holding the defect the rest of the app had fixed.
    private func friendly(_ error: Error) -> String {
        if case .server(_, let code, _) = error as? AuthError,
           code == "redirect_uri_not_allowed" || code == "invalid_redirect_uri" {
            // Configuration rather than a fault, and the only failure here
            // worth naming precisely — the generic sentence would send
            // somebody looking for a network problem that is not there.
            // The identifiers stay in Latin because they are things to
            // copy, not words to read.
            return """
            Сървърът отхвърли адреса за връщане на това приложение. \
            Добавете \(Config.redirectURI) в NATIVE_AUTH_REDIRECT_ALLOWLIST \
            на сървъра и го рестартирайте. Вижте README.
            """
        }
        if case .server(let status, let code, let message) = error as? AuthError {
            return UserMessage.httpText(status: status, code: code, message: message)
        }
        return UserMessage.text(for: error)
    }

    private struct ExchangeResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }
}

/// A refusal from the auth endpoints, taken apart rather than carried whole.
///
/// It was `case server(String)` holding the raw response body, and
/// `friendly` returned that string unchanged — so the sign-in screen could
/// render `{"error":{"code":"invalid_grant","message":"…"}}` at a farmer.
/// Structured now, for the same reason and in the same shape as
/// `APIError.http`.
enum AuthError: Error {
    case server(status: Int, code: String?, message: String?)
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
