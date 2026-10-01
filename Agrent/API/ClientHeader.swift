import Foundation

/// `X-Agrent-Client: ios/<major>.<minor>` — on EVERY request this app sends.
///
/// The grammar is the server's (agri-saas P0.5, roadmap #1191 P0.9), sent to
/// this session on 2026-10-01 and fixed:
///
///     <platform>/<major>.<minor>     platform ∈ ios | android | web
///                                    1–3 digits each, ASCII, ≤ 32 bytes
///
/// ── Major.minor and NOTHING else ──
///
/// The value becomes a counter dimension (platform × version × route
/// template). A patch or build number would make that dimension grow with
/// every release; major.minor still answers what the counter is for — "is
/// anyone still on 1.0, can this route change" — from a bounded set. No
/// device id, no form factor: those are different questions, and a value
/// that parses two ways is how a telemetry field becomes unparseable.
///
/// ── Every request, from one place ──
///
/// The SERVER decides what to count, with its own allowlist of route
/// templates. Sending selectively would put that list in two codebases.
/// So each `URLRequest` this app builds goes through `stamp(_:)`, and a
/// source test holds that there is no other way to build one.
///
/// ── It can never cost a request ──
///
/// The server buckets an absent value as `unknown` and anything it does not
/// recognise as `other` — never a 4xx. So a version this file computes
/// wrongly degrades a counter, not the app. That is also why a version that
/// does not fit the grammar is SENT AS `ios/0.0` rather than dropped or
/// clipped: the platform is still true, and a nonsense version is easier
/// to spot in the counter than a missing header.
enum ClientHeader {
    static let name = "X-Agrent-Client"

    /// Computed once — the bundle does not change while the app runs.
    static let value: String = make(shortVersion:
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    /// `0.1.0` → `ios/0.1`. Pure, so the grammar is testable without a bundle.
    static func make(shortVersion: String?) -> String {
        let parts = (shortVersion ?? "").split(separator: ".", omittingEmptySubsequences: false)
        func component(_ i: Int) -> String? {
            guard i < parts.count else { return nil }
            let s = String(parts[i])
            guard (1...3).contains(s.count), s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber)
            else { return nil }
            return s
        }
        // A bare "1" is major 1, minor 0 — Apple allows a one-component
        // CFBundleShortVersionString, and "ios/1" would not match the grammar.
        guard let major = component(0) else { return "ios/0.0" }
        let minor = parts.count > 1 ? component(1) : "0"
        guard let minor else { return "ios/0.0" }
        return "ios/\(major).\(minor)"
    }

    /// The single place a request gets the header.
    static func stamp(_ request: inout URLRequest) {
        request.setValue(value, forHTTPHeaderField: name)
    }
}
