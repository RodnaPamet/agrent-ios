import Foundation
import os

/// The app had NO logging of any kind until Phase 0, and that cost a full day
/// twice over on 2026-09-21. `no_handoff` surfaced as a raw JSON blob inside a
/// browser sheet; a 404 surfaced as a blank screen with its own retry button
/// pushed out of view. Both times the only record of what actually happened
/// lived in the OS network log — which is not something an operator standing in
/// a field can send you.
///
/// THREE THINGS MUST NEVER REACH THE UNIFIED LOG. This file is shaped so that
/// they *cannot*, rather than so that you remember not to write them:
///
///  1. ACCESS OR REFRESH TOKENS. Not truncated, not hashed, not "just the
///     prefix". `os_log` persists and outlives the process, so a token in the
///     log is a token on disk. No function here accepts a `Tokens` or any
///     token string — there is no overload that would take one.
///
///  2. RESPONSE BODIES. Journal entries are a regulatory record, and the БАБХ
///     profile carries ЕГН/ЕИК which agri-saas encrypts at rest precisely so
///     it is never in the clear. Every function here takes a byte COUNT; none
///     takes `Data`. See `summary(for:)` for why the *error* cannot leak one
///     either.
///
///  3. QUERY STRINGS, for the same reason — a query carries filter values, and
///     filter values are data. A path reaches the log only as a `LoggablePath`,
///     whose initialiser drops everything from the first "?" onward. There is
///     no entry point that takes a bare `String` path.
///
/// Privacy markers are explicit everywhere below. `Logger` defaults interpolated
/// strings to private and numbers to public, but relying on a default is how
/// the next person ends up redacting the wrong half.
enum Log {
    static let subsystem = "bg.agrent.app"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let cache = Logger(subsystem: subsystem, category: "cache")

    // MARK: - API

    static func request(_ method: String, _ path: LoggablePath) {
        api.debug("→ \(method, privacy: .public) \(path.value, privacy: .public)")
    }

    static func response(
        _ method: String, _ path: LoggablePath, status: Int, bytes: Int, ms: Int
    ) {
        api.info(
            """
            ← \(status, privacy: .public) \(method, privacy: .public) \
            \(path.value, privacy: .public) \(bytes, privacy: .public)B \
            \(ms, privacy: .public)ms
            """
        )
    }

    static func failure(_ method: String, _ path: LoggablePath, _ error: Error) {
        api.error(
            """
            ✗ \(method, privacy: .public) \(path.value, privacy: .public) \
            \(summary(for: error), privacy: .public)
            """
        )
    }

    /// A one-line error summary that is SAFE TO PERSIST.
    ///
    /// Deliberately not `error.localizedDescription`. `APIError.http` used to
    /// embed up to 300 characters of the response BODY in its description,
    /// and a JSON error body is still a body — rule 2 above forbids exactly
    /// that, so only the status survived here.
    ///
    /// The envelope is now taken apart at the client, which makes the `code`
    /// available separately, and a code is SAFE: it is a fixed identifier
    /// chosen by the server's authors, not a payload, not interpolated with
    /// anything, and it is the same string for every tenant that hits the
    /// same condition. So the log gets strictly more useful without getting
    /// less clean — `APIError.http(404, INVALID_PARCEL)` names the actual
    /// failure where `APIError.http(404)` named a category.
    ///
    /// `message` is still dropped, and that is not an oversight. It is prose
    /// the server composed, it interpolates ids today, and it is exactly the
    /// kind of field that grows a name or an email in it one day without
    /// anyone thinking about this file.
    static func summary(for error: Error) -> String {
        switch error {
        case let api as APIClient.APIError:
            switch api {
            case .notSignedIn: return "APIError.notSignedIn"
            case .conflict: return "APIError.conflict"
            case .clientTooOld: return "APIError.clientTooOld"
            case .notModified: return "APIError.notModified"
            case .http(let status, let code, _, _):
                return code.map { "APIError.http(\(status), \($0))" }
                    ?? "APIError.http(\(status))"
            }
        case let url as URLError:
            return "URLError(\(url.code.rawValue))"
        case is DecodingError:
            return "DecodingError"
        default:
            return String(describing: type(of: error))
        }
    }
}

/// A request path whose query string is removed AT CONSTRUCTION.
///
/// The point is that there is no way to log a path *without* going through this
/// initialiser, so a query string cannot reach the log by someone forgetting to
/// strip one. `/api/t/agrent/journal?limit=50` logs as `/api/t/agrent/journal`.
struct LoggablePath: Sendable {
    let value: String

    init(_ pathAndQuery: String) {
        value = String(pathAndQuery.prefix(while: { $0 != "?" }))
    }
}
