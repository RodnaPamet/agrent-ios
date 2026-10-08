import Foundation
import Observation

/// Accepting the terms of use IN THE APP (agrent-ios#193, P4.4).
///
/// ── Why the app needs this at all ──
///
/// A first Sign in with Apple creates the account with no consent recorded
/// — there is no browser in that flow, and stamping consent on the server
/// would file an agreement nobody gave — and answers `termsPending: true`.
/// From then on every farm and person route is a 403 until the person accepts
/// (`POST /api/auth/accept-terms`). Sending them to the web is no way out for
/// an Apple-only account. So the app shows the terms and records the answer.
///
/// ── The version they READ is the version sent ──
///
/// accept-terms compares `termsVersion` with the version being served, so a
/// screen left open across a terms change cannot file consent to a document
/// nobody read. `GET /api/auth/terms` (agri-saas, built for this) says which
/// version that is and where to read it. A `terms_version_stale` refusal means
/// the terms changed while they were open: the screen fetches the new version
/// and asks again. It NEVER resends with the server's `currentVersion` —
/// that would record consent to a version the person did not see.
enum TermsAPI {
    /// Under `/api/auth/` on purpose (agri-saas): already public and already
    /// reachable by a session the terms gate holds, so neither gate needs an
    /// entry it could be forgotten in.
    static let currentPath = "/api/auth/terms"
    static let acceptPath = "/api/auth/accept-terms"

    /// `{ version, url }`. `url` is the page to read, relative (`/terms`): the
    /// product is served on more than one host.
    struct Current: Decodable, Equatable, Sendable {
        let version: String
        let url: String

        /// `url` on the API host when relative; as given when absolute.
        var page: URL? {
            if let absolute = URL(string: url), absolute.scheme != nil { return absolute }
            return URL(string: url, relativeTo: Config.baseURL)?.absoluteURL
        }
    }

    /// `acceptedTerms` is literally `true` — the server checks identity, not
    /// truthiness — and `termsVersion` is the version that was SHOWN.
    struct Accept: Encodable, Equatable, Sendable {
        let acceptedTerms: Bool
        let termsVersion: String

        init(shown version: String) {
            acceptedTerms = true
            termsVersion = version
        }
    }

    struct Accepted: Decodable, Equatable, Sendable {
        let ok: Bool
        let version: String
    }

    static func current() async throws -> Current {
        try await APIClient.shared.get(currentPath, as: Current.self)
    }

    /// RECORDS CONSENT — a write. Nothing in development, CI or A11yShots
    /// sends it: under the UI-test seam every write is a 501 that never
    /// leaves the process, and the first real one is the person's own tap.
    static func accept(_ body: Accept) async throws -> Accepted {
        try await APIClient.shared.post(acceptPath, body: body, as: Accepted.self)
    }

    /// The terms changed while they were open.
    static func isStale(_ error: Error) -> Bool {
        guard case APIClient.APIError.http(_, let code, _, _, _) = error else { return false }
        return code == "terms_version_stale"
    }
}

/// The terms screen's state: which version is shown, and the acceptance.
@Observable
@MainActor
final class TermsStore {
    enum State: Equatable {
        case loading
        case ready(TermsAPI.Current)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var accepting = false
    /// Why the last «Приемам» did not land, said under the button.
    private(set) var acceptFailure: String?

    @ObservationIgnored private let fetch: @MainActor () async throws -> TermsAPI.Current
    @ObservationIgnored private let send: @MainActor (TermsAPI.Accept) async throws -> TermsAPI.Accepted

    init(
        fetch: @escaping @MainActor () async throws -> TermsAPI.Current = { try await TermsAPI.current() },
        send: @escaping @MainActor (TermsAPI.Accept) async throws -> TermsAPI.Accepted = {
            try await TermsAPI.accept($0)
        }
    ) {
        self.fetch = fetch
        self.send = send
    }

    func load() async {
        if case .ready = state {} else { state = .loading }
        do {
            state = .ready(try await fetch())
        } catch let APIClient.APIError.http(status, _, _, _, _) where status == 404 {
            // The route is not on this server yet — not the person's network.
            state = .failed(TermsText.notYet)
        } catch {
            state = .failed(TermsText.unavailable)
        }
    }

    /// Accept the version on screen. Returns whether it landed.
    ///
    /// `accepting` stays true on success: the screen is handing over to the
    /// signed-in app (`AuthClient.termsAccepted`), and a button that came
    /// back meanwhile would send the acceptance again.
    @discardableResult
    func accept() async -> Bool {
        guard case .ready(let shown) = state, !accepting else { return false }
        accepting = true
        acceptFailure = nil
        do {
            _ = try await send(TermsAPI.Accept(shown: shown.version))
            return true
        } catch where TermsAPI.isStale(error) {
            accepting = false
            // The terms changed under the open screen: show the new version
            // and ask again. Never the server's `currentVersion` — see header.
            acceptFailure = TermsText.changed
            await load()
            return false
        } catch {
            accepting = false
            acceptFailure = UserMessage.text(for: error)
            return false
        }
    }
}

enum TermsText {
    static let title = "Условия за ползване"
    static let lead = "За да продължите, прочетете условията за ползване на Agrent и ги приемете."
    static let read = "Прочетете условията"
    static let accept = "Приемам условията"
    static let changed = "Условията се промениха, докато ги четяхте. Прочетете новата версия и ги приемете отново."
    static let unavailable = "Условията не могат да бъдат заредени в момента. Проверете връзката и опитайте отново."
    /// The server does not serve the terms to the app yet (`GET
    /// /api/auth/terms` not deployed).
    static let notYet = "Условията все още не могат да бъдат показани в приложението. Опитайте отново по-късно."
    static let accepting = "Приемане на условията"
}
