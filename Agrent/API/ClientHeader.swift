import Foundation

/// Two headers on EVERY request this app sends, set in one place:
///
///     X-Agrent-Client: ios/<major>.<minor>     which BUILD    — a usage counter
///     x-agrent-client-version: <contract>      which CONTRACT — the version gate
///
/// They answer different questions and must not be merged. The first is
/// telemetry and can never cost a request; the second is the one header the
/// server may turn a request away over, and that is what it is for
/// (agrent-ios#169; see `contractVersion`).
///
/// ── `X-Agrent-Client`: the grammar is the server's ──
///
/// agri-saas P0.5, roadmap #1191 P0.9, sent to this session on 2026-10-01
/// and fixed:
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
/// source test holds that there is no other way to build one. The version
/// gate rides the same rule: a request that skipped it would be served by a
/// server that has retired this build, and fail on shapes the build no
/// longer reads, instead of being told to update.
///
/// ── `X-Agrent-Client` can never cost a request ──
///
/// The server buckets an absent value as `unknown` and anything it does not
/// recognise as `other` — never a 4xx. So a version this file computes
/// wrongly degrades a counter, not the app.
///
/// ── An unreadable version sends NO `X-Agrent-Client` ──
///
/// It first sent `ios/0.0`, on the theory that a nonsense version is easy
/// to spot. The server session pointed out the flaw (2026-10-01): `0.0`
/// PARSES, so it is counted as a real version — indistinguishable from "we
/// could not read it", and colliding with a genuine 0.0. An absent header
/// is bucketed as `unknown`, which is exactly what it is. The contract is
/// still declared: see `stamp(_:client:)`.
enum ClientHeader {
    static let name = "X-Agrent-Client"

    /// Computed once — the bundle does not change while the app runs.
    static let value: String? = make(shortVersion:
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    /// The header the server's version gate reads, spelt as the spec spells
    /// it (`x-client-version-header`; agri-saas `CLIENT_VERSION_HEADER` in
    /// `src/lib/api/contract-version.ts`), so a search for either finds this.
    static let contractVersionHeader = "x-agrent-client-version"

    /// THE API CONTRACT THIS BUILD WAS WRITTEN AGAINST: agri-saas's
    /// `x-api-version` (`API_CONTRACT_VERSION`) — 2 since agri-saas #1390,
    /// live 2026-10-08 (`/api/health` at its merge commit 8d3e5a4c, and the
    /// spec's top-level `x-api-version` read there), with
    /// `x-minimum-client-version` still 1. It was 1 at main 261463d.
    ///
    /// Contract 2 split `Task` into `TaskListItem` (`GET /tasks`,
    /// `/farm-tasks`) and `TaskDetail`, documenting what the server always
    /// sent. This build decodes them as `WorkItemSummary` and `WorkItem`, and
    /// requires no field either schema leaves out of `required` — which is
    /// what makes the claim below true (agrent-ios#185).
    ///
    /// ── Why it is declared (#169, owner 2026-10-07) ──
    ///
    /// The gate (`src/middleware.ts`, step 2c) answers 426
    /// `client_version_unsupported` to a request that DECLARES a version below
    /// the server's floor, and serves an absent or unparseable header as
    /// compatible — the web ships with the server and sends none. So before
    /// this was sent, no floor could retire an iOS build: an installed copy
    /// would go on being served after a breaking change and fail on the new
    /// shapes, a decode error or a 400, instead of meeting the 426 that the
    /// outbox stops on and its banner turns into "update the app" (#168).
    /// Declaring opts this app INTO being refused; that is the point.
    ///
    /// The gate stands after the session check and only on `/api/` paths
    /// that are not public. Everything under `/api/auth` — the exchange, the
    /// refresh, `/me`, the revoke — is public there, so a retired build can
    /// still sign in and say who it is; the farm's data routes answer 426.
    ///
    /// ── Raised ONLY in a release that understands the newer contract ──
    ///
    /// The server's sequence for a break is app first
    /// (`docs/api-compatibility.md`): a build that reads the NEW shapes — and
    /// still the old ones, which it meets until the server moves — ships and
    /// is adopted, only then does the server bump its contract, and the
    /// floor rises after the support window, as a change of its own. This
    /// number is a claim about what the code decodes, so it moves in the
    /// release that makes the claim true, and never on its own. Raised ahead
    /// of the code, a build the server has moved past would be served and
    /// break; left behind it, a build that does understand would be turned
    /// away once the floor passes the old number. ROADMAP, «Decisions
    /// locked» 7; `ClientHeaderTests` pins the value so a change is noticed.
    ///
    /// ── Not derived from the app's version ──
    ///
    /// The app's version moves every release and the contract only on a
    /// breaking change. Derived, every release would claim a new contract.
    ///
    /// Sent as its decimal digits: the gate reads `parseInt(value, 10)` and
    /// serves anything at or above its floor. Zero, a negative number or a
    /// non-number is "unparseable" there and served like no header at all —
    /// a build that could never be retired, with nothing to say so. Hence an
    /// `Int`, above zero, rather than a string someone might format.
    static let contractVersion = 2

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

    /// The single place a request gets its headers.
    /// Every request goes through here, even when there is no
    /// `X-Agrent-Client` to send — so "every request is stamped" stays one
    /// rule with no exceptions.
    ///
    /// The contract FIRST, and whatever the bundle says: it is compiled in,
    /// so it cannot be unreadable the way the version string can, and a build
    /// with a malformed version string is still a build the gate must be able
    /// to retire. `client` is `value` at every call site in the app — the
    /// source test accepts no other — and a parameter only so a test can show
    /// the two headers are independent.
    static func stamp(_ request: inout URLRequest, client: String? = ClientHeader.value) {
        request.setValue(String(contractVersion), forHTTPHeaderField: contractVersionHeader)
        guard let client else { return }
        request.setValue(client, forHTTPHeaderField: name)
    }
}
