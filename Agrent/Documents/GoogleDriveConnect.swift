import AuthenticationServices
import UIKit

/// «Копие в Google Drive» turned on for a farm with no Google account yet:
/// Google's consent, then back to the app (owner, 2026-10-30: «opens the
/// federated sign in to the google account»).
///
/// ── The native variant, not the web's ──
///
/// The web's connect sets a state cookie in the API session and its callback
/// reads it from the browser. That is a different cookie jar here (the
/// sheet is ephemeral, as sign-in's is), and the callback lands on a web
/// page. So the phone asks for the native flow, agreed with backend 1 as
/// #2495 step 6: `{"client":"ios"}` returns an `authorizeUrl` whose state is
/// a server-held single-use nonce, and the callback returns to
/// `bg.agrent.app://integrations/google?result=connected` or `?error=CODE`
/// on the same allowlist sign-in uses.
@MainActor
final class GoogleDriveConnect: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated static var connectPath: String { "\(FarmPath.root)/admin/integrations/google/connect" }

    /// The runtime flag both connect branches sit behind (agri-saas #2581):
    /// off, the route answers 404, so the switch says so instead of trying.
    nonisolated static let flag = "integrations.google"

    enum Outcome: Equatable {
        case connected
        case cancelled
        case refused(String)
    }

    private var session: ASWebAuthenticationSession?

    struct Request: Encodable, Sendable { let client = "ios" }
    struct Answer: Decodable, Sendable { let authorizeUrl: URL }

    /// Consent, and what came back. A cancelled sheet is not an error: the
    /// switch simply stays off.
    func run() async -> Outcome {
        let answer: Answer
        do {
            let data = try await APIClient.shared.postReturningData(
                Self.connectPath, body: Request(), idempotencyKey: nil)
            answer = try await APIClient.shared.decode(data, as: Answer.self)
        } catch {
            return .refused(UserMessage.text(for: error))
        }
        do {
            let callback = try await present(answer.authorizeUrl)
            return Self.outcome(of: callback)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        } catch {
            return .refused(UserMessage.text(for: error))
        }
    }

    /// The callback's `result` or `error`, read without trusting anything
    /// else in it. The error is a CODE from a closed set agreed with backend
    /// 1 (agri-saas #2495, 2026-10-31), never prose; anything outside it is
    /// read as `internal_error`, the set's own fallback. A sheet the farmer
    /// closes sends no callback at all: that is `.cancelled`, from
    /// `ASWebAuthenticationSession`, not a code.
    nonisolated static func outcome(of callback: URL) -> Outcome {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.first(where: { $0.name == "result" })?.value == "connected" { return .connected }
        return .refused(sentence(for: items.first(where: { $0.name == "error" })?.value))
    }

    nonisolated static func sentence(for code: String?) -> String {
        switch code {
        // Cancelled on Google's own screen.
        case "access_denied": "Отказахте достъпа до Google Drive."
        // Signed in, but unticked Drive: the commonest recoverable mistake,
        // which is why it has its own code.
        case "insufficient_scope": "Разрешете достъпа до Google Drive, за да се пазят копия на документите."
        case "state_expired": "Времето за свързване с Google изтече. Опитайте отново."
        // Missing, mismatched or already used: start again.
        case "state_invalid": "Свързването с Google не успя. Започнете отначало."
        case "token_exchange_failed": "Google не потвърди свързването. Опитайте отново."
        case "not_admin": "Само собственик или администратор може да свърже Google Drive."
        default: "Нещо се обърка при свързването с Google. Опитайте отново."
        }
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Config.redirectScheme) { callback, error in
                if let error { cont.resume(throwing: error) }
                else if let callback { cont.resume(returning: callback) }
                else { cont.resume(throwing: URLError(.badServerResponse)) }
            }
            s.presentationContextProvider = self
            // Its own cookie jar, as sign-in's (#379): the farm's Google
            // account is chosen here, not whichever one Safari has open.
            s.prefersEphemeralWebBrowserSession = true
            session = s
            s.start()
        }
    }

    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
