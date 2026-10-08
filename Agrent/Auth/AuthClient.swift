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
        /// Signed in, but the account has not accepted the terms of use — a
        /// first Sign in with Apple. Only `TermsAcceptanceView` is shown: the
        /// server answers 403 to every farm and person route until it is
        /// done (agrent-ios#193).
        case termsPending
        case failed(String)
    }

    /// Who signs a person in through the system browser. Both are the
    /// server's configured identity providers; the id is its own
    /// (`/api/auth/native/start?provider=`, which refuses anything else).
    enum Provider: String, Sendable {
        case google = "google"
        case microsoft = "microsoft-entra-id"
    }

    private(set) var state: State = .signedOut
    private var session: ASWebAuthenticationSession?

    /// Which way a sign-in in progress went, so the busy indicator is on
    /// THAT button — and VoiceOver hears it named — rather than always on
    /// Google's.
    enum Route: Equatable, Sendable { case google, microsoft, apple }
    private(set) var signingInVia: Route?

    /// The RAW nonce of each Apple request on its way, by the `state` string
    /// the request carries and Apple echoes on the credential. One per
    /// attempt and used once: the server claims a nonce before it answers, so
    /// the same one sent twice is a replay to it (`AppleSignIn`). Keyed, not
    /// one slot: two requests that overlap — a double tap before Apple's sheet
    /// is up — must not overwrite each other's nonce.
    private var appleNonces: [String: String] = [:]

    private var termsObserver: NSObjectProtocol?

    override init() {
        super.init()
        if let tokens = TokenStore.load() {
            state = tokens.termsPending == true ? .termsPending : .signedIn
        }
        // A route answered the terms gate's 403 (`APIClient`): this session
        // goes to the terms screen, whichever provider it came from.
        termsObserver = NotificationCenter.default.addObserver(
            forName: APIClient.termsPendingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.termsRefused() }
        }
    }

    /// Only a signed-in session moves; one signing in, out or already on the
    /// terms screen is left as it is.
    func termsRefused() {
        guard state == .signedIn else { return }
        state = .termsPending
        Log.auth.info("terms gate refused a request; showing the terms")
    }

    func signIn(with provider: Provider = .google) async {
        state = .signingIn
        signingInVia = provider == .google ? .google : .microsoft
        defer { signingInVia = nil }
        Log.auth.info("sign-in started (\(provider.rawValue, privacy: .public))")
        let pkce = PKCE()

        var comps = URLComponents(
            url: Config.baseURL.appending(path: "/api/auth/native/start"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "provider", value: provider.rawValue),
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
            // WHO, before the first screen. The identity keys the response
            // cache and owns the outbox; until it is known both are off (see
            // `SessionIdentity`). The phone has signal this instant — it just
            // completed the exchange — so this is the cheapest moment there
            // will be. Not fatal if it fails: `MainTabView` asks again.
            _ = await CurrentUserStore.shared.load()
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

    // MARK: - Sign in with Apple (agrent-ios#193)

    /// Configure Apple's request: a FRESH nonce for this attempt — its hash to
    /// Apple, the raw value kept for the exchange — and the email, which
    /// Apple sends only on a first authorisation and the server needs to
    /// create or find the account.
    ///
    /// The email only: the server reads nothing else, and Apple gives a name
    /// once, on the first authorisation — asked for and not sent, it would be
    /// collected and lost.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let raw = AppleSignIn.makeNonce()
        let key = UUID().uuidString
        // Bounded: a request Apple never answers leaves its entry behind.
        if appleNonces.count >= 8 { appleNonces.removeAll() }
        appleNonces[key] = raw
        request.state = key
        request.requestedScopes = [.email]
        request.nonce = AppleSignIn.hashed(raw)
    }

    /// The Apple requests waiting for an answer — for tests.
    var appleRequestsInFlight: Int { appleNonces.count }

    /// Apple's answer: trade its identity token for this app's pair.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        // An answer while a sign-in is already running belongs to a request
        // that overlapped it: it neither cancels that sign-in nor races it.
        guard state != .signingIn else {
            if case .success(let authorization) = result,
               let key = (authorization.credential as? ASAuthorizationAppleIDCredential)?.state {
                appleNonces[key] = nil
            }
            Log.auth.info("apple answer ignored: a sign-in is already running")
            return
        }
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                state = .signedOut
                Log.auth.info("apple sign-in cancelled by user")
            } else {
                state = .failed(AppleSignIn.Text.unavailableHere)
                Log.auth.error("apple authorization failed: \(Log.summary(for: error), privacy: .public)")
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let key = credential.state,
                  // Used up here, whatever happens next: a retry is a new
                  // request with a new nonce.
                  let raw = appleNonces.removeValue(forKey: key),
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8)
            else {
                state = .failed(AppleSignIn.Text.failed)
                Log.auth.error("apple credential unusable: no identity token, or no nonce for its request")
                return
            }
            state = .signingIn
            signingInVia = .apple
            defer { signingInVia = nil }
            do {
                if try await exchangeApple(identityToken: token, nonce: raw) {
                    state = .termsPending
                    Log.auth.info("apple sign-in complete, terms pending")
                } else {
                    _ = await CurrentUserStore.shared.load()
                    state = .signedIn
                    Log.auth.info("apple sign-in complete")
                }
            } catch {
                if case .server(let status, let code, _) = error as? AuthError {
                    state = .failed(AppleSignIn.message(status: status, code: code))
                    // The server's code is not secret, and it is the only
                    // thing that tells `email_required` from `invalid_grant`.
                    Log.auth.error("apple exchange refused: \(status, privacy: .public) \(code ?? "no code", privacy: .public)")
                } else {
                    state = .failed(friendly(error))
                    Log.auth.error("apple sign-in failed: \(Log.summary(for: error), privacy: .public)")
                }
            }
        }
    }

    /// The terms are accepted (`TermsAcceptanceView`): the session is an
    /// ordinary one from here.
    ///
    /// The flag off and the access token expired in one step on `APIClient`
    /// (see `APIClient.termsAccepted`), so `/me` — the next request — first
    /// refreshes into a token minted after the acceptance. And only for the
    /// session that accepted: an Изход, or another sign-in, while this was
    /// out is not overruled by its answer.
    func termsAccepted() async {
        guard state == .termsPending else { return }
        let epoch = SessionEpoch.current
        await APIClient.shared.termsAccepted()
        _ = await CurrentUserStore.shared.load()
        guard SessionEpoch.isCurrent(epoch), state == .termsPending else { return }
        state = .signedIn
        Log.auth.info("terms accepted")
    }

    /// Returns whether the new account's terms are pending.
    private func exchangeApple(identityToken: String, nonce: String) async throws -> Bool {
        var req = URLRequest(url: Config.baseURL.appending(path: AppleSignIn.path))
        ClientHeader.stamp(&req)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AppleSignIn.Request(identityToken: identityToken, nonce: nonce))

        // `NoURLCache.session`, as for the code exchange: the 200 carries the
        // pair. The identity token is never logged.
        let (data, response) = try await NoURLCache.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        Log.auth.info("apple exchange → \(status, privacy: .public)")
        guard status == 200 else {
            let env = APIClient.envelope(from: data)
            throw AuthError.server(status: status, code: env?.code, message: env?.message)
        }
        let granted = try JSONDecoder().decode(AppleSignIn.Granted.self, from: data)
        // From nothing, as every sign-in starts — see `exchange`.
        SessionReset.beginFreshSession()
        TokenStore.save(Tokens(
            accessToken: granted.accessToken,
            refreshToken: granted.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(granted.expiresIn)),
            termsPending: granted.termsPending ? true : nil
        ))
        return granted.termsPending
    }

    func signOut() {
        #if DEBUG
        // UNDER THE SEAM THE KEYCHAIN IS NOT OURS TO CLEAR.
        //
        // The seam was written for a runner, whose Keychain is empty, and on
        // that reading `TokenStore.clear()` is a no-op. It is not a no-op on
        // the machine the seam is actually used on: the screenshot harness
        // runs against the owner's SIGNED-IN simulator, and there this line
        // destroys a real Google session that has to be re-established
        // through a browser.
        //
        // Silently, which is the worse half. `AgrentApp.openingState` returns
        // `.signedIn` whenever the seam is on, so the app carries on showing
        // `MainTabView` with the tokens already gone. Nothing on screen
        // changes at the moment the damage is done.
        //
        // The seam does not read the Keychain — `APIClient` hands out
        // `UITestSeam.stubTokens` — so there is nothing of the seam's to
        // clear here and nothing to lose by not clearing it.
        //
        // The singletons ARE the seam's to reset — they hold fixture data in
        // this process and nothing else — so the in-memory half of a real
        // sign-out still runs. The response cache is NOT purged: under the
        // seam its fixture entries are keyed on the fixture user, so the
        // owner's real entries are not the seam's to delete either.
        if UITestSeam.isActive {
            SessionReset.endSession(clearTokens: {}, cache: nil)
            state = .signedOut
            return
        }
        #endif

        // Read BEFORE the local clear, for the revoke below: `endSession`
        // deletes the Keychain item, and after it there is nothing to send.
        let refreshToken = TokenStore.load()?.refreshToken

        // ── LOCAL FIRST, AND WHOLE ──
        //
        // Tokens, identity, every per-user singleton and the response cache
        // (agri-saas#1191 P0.9 — see `SessionReset` for the list and the
        // reason for each entry). Synchronous and network-free: this cannot
        // fail for lack of signal, which is where a farm phone is when its
        // owner hands it to the next person.
        SessionReset.endSession()

        // ── THEN the server, best-effort ──
        //
        // `POST /api/auth/native/revoke` (agri-saas#1206): this device's
        // session only, one attempt in a detached task. NOT
        // `/api/auth/logout`: that clears a web cookie and would revoke
        // nothing. After the local clear and never awaited, so the network
        // can neither delay nor undo the sign-out — see `SessionRevocation`,
        // including what "this device's session" can reach in Safari.
        SessionRevocation.revokeThisDevice(refreshToken: refreshToken)

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
        ClientHeader.stamp(&req)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "code_verifier": verifier])

        // `NoURLCache.session`, not `URLSession.shared`: this POST is not
        // cacheable, but its 200 carries the access AND refresh tokens, and
        // "nothing lands in Cache.db" is cheaper to hold as a rule than to
        // argue per request (#134).
        let (data, response) = try await NoURLCache.session.data(for: req)
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
        // A sign-in starts from NOTHING, before the new pair is saved — not
        // every session ends with Изход (a refused refresh clears only the
        // tokens), and the next account must not inherit what that left.
        SessionReset.beginFreshSession()
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
