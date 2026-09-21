import Foundation

/// What to show an OPERATOR when something fails, in Bulgarian.
///
/// Not `error.localizedDescription`. Foundation localises to the device
/// locale, and this phone reports en-BG, so an all-Bulgarian screen rendered
/// English. Both offline proofs in Phase 0 produced exactly that:
///
///     Неуспешно зареждане
///     Could not connect to the server.          ← URLError
///
///     Неуспешно зареждане
///     The data couldn't be read because it      ← DecodingError
///     isn't in the correct format.
///
/// The whole argument for the failure path is that the person holding the
/// phone can read it and decide what to do. An English sentence under a
/// Bulgarian heading fails that for the operator this app is actually for,
/// and it fails it precisely when they are in a field with no signal.
///
/// Deliberately NOT a full localisation pass: the app has no string catalogue
/// and every other literal in it is hard-coded Bulgarian. This matches that,
/// rather than pretending to a system that does not exist yet.
enum UserMessage {
    static func text(for error: Error) -> String {
        switch error {
        case let api as APIClient.APIError:
            // Already written for an operator — see APIError.errorDescription.
            return api.errorDescription ?? fallback

        case let url as URLError:
            switch url.code {
            case .notConnectedToInternet:
                return "Няма интернет връзка."
            case .timedOut:
                return "Сървърът не отговори навреме."
            case .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return "Няма връзка със сървъра."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "Проблем със защитената връзка."
            default:
                return "Мрежова грешка."
            }

        case is DecodingError:
            // The operator can do nothing about this one, so it says what
            // happened rather than what to try.
            return "Сървърът върна отговор в неочакван формат."

        default:
            return fallback
        }
    }

    private static var fallback: String { "Възникна неочаквана грешка." }
}
