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
/// wrongly degrades a counter, not the app.
///
/// ── An unreadable version sends NO header ──
///
/// It first sent `ios/0.0`, on the theory that a nonsense version is easy
/// to spot. The server session pointed out the flaw (2026-10-01): `0.0`
/// PARSES, so it is counted as a real version — indistinguishable from "we
/// could not read it", and colliding with a genuine 0.0. An absent header
/// is bucketed as `unknown`, which is exactly what it is.
enum ClientHeader {
    static let name = "X-Agrent-Client"

    /// Computed once — the bundle does not change while the app runs.
    static let value: String? = make(shortVersion:
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    /// `0.1.0` → `ios/0.1`; nil when the version does not fit the grammar.
    /// Pure, so the grammar is testable without a bundle.
    static func make(shortVersion: String?) -> String? {
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
        guard let major = component(0) else { return nil }
        let minor = parts.count > 1 ? component(1) : "0"
        guard let minor else { return nil }
        return "ios/\(major).\(minor)"
    }

    /// The single place a request gets the header.
    /// Every request goes through here, even when there is nothing to send —
    /// so "every request is stamped" stays one rule with no exceptions.
    static func stamp(_ request: inout URLRequest) {
        guard let value else { return }
        request.setValue(value, forHTTPHeaderField: name)
    }
}
