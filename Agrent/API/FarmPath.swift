import Foundation

/// Where every farm-scoped path starts: `/api/t/<farm>` (agrent-ios#192, P4.3).
///
/// ── No fallback, by design ──
///
/// This replaces `Config.tenantSlug`, which answered the farm the app was
/// pinned to (`Config.pinnedFarmSlug`) whenever no farm was open. No screen
/// reached that — `FarmGate` shows nothing farm-scoped without a farm — but a
/// request built in that state (a read that outlives Изход, background work,
/// a test) went to a farm the person never chose, and a farm the server would
/// happily answer for anyone who belongs to it.
///
/// Now such a path has NO farm in it: `/api/t/` and then nothing, which no
/// route matches, and `APIClient` refuses it before anything is sent — the
/// token refresh included (`APIError.noFarmOpen`). The worst case is
/// nowhere, never the wrong farm.
///
/// ── The one place a farm path starts ──
///
/// Every builder starts from `root`, or from `root(for:)` for a queued record
/// that goes where it was made. A CI guard fails on `Config.tenantSlug` and on
/// any `"/api/t/` literal outside this file.
enum FarmPath {
    static let prefix = "/api/t/"

    /// The open farm's slug, or nil when none is open.
    static var openSlug: String? { ActiveFarm.shared.farm?.slug }

    /// `/api/t/<the open farm>` — `/api/t/` and nothing when none is open.
    static var root: String { root(for: openSlug) }

    /// `/api/t/<farm>`, for a farm named explicitly: a queued record's, which
    /// goes where it was made whichever farm is open when it is sent.
    static func root(for farm: String?) -> String { prefix + (farm ?? "") }

    /// A farm path with no farm in it — what `root` builds when none is open:
    /// `/api/t//…`, or the bare root itself.
    static func isUnscoped(_ path: String) -> Bool {
        let path = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? path
        return path == prefix || path.hasPrefix(prefix + "/")
    }
}
