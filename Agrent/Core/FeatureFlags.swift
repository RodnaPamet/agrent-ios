import Foundation
import Observation

/// Runtime feature flags, as `GET /api/auth/me` resolved them for THIS caller
/// (agri-saas#1209, roadmap P0.4; consumed here for P0.9, agri-saas#1191).
///
/// ── The client does no flag logic, on purpose ──
///
/// The server narrows cohort-gated flags per caller before answering, so a
/// key that is `true` here is `true` for this person. There is nothing to
/// evaluate, and a second copy of the cohort rules on the phone would be a
/// second place for them to disagree.
///
/// ── Absent means OFF, and so does everything else that is not `true` ──
///
///   · a key that is not in the map           → off. There are NO local
///                                              defaults, and none may be true:
///                                              a default-on would show a
///                                              surface nobody enabled.
///   · `featureFlags: {}`                      → all off. That is the server's
///                                              GLOBAL KILL SWITCH answering
///                                              (`FEATURE_FLAGS_FORCE_OFF`), not
///                                              "the server sent nothing, use
///                                              defaults". Reading it as the
///                                              latter would make the kill
///                                              switch turn things ON.
///   · no `featureFlags` key at all            → all off. An older server that
///                                              predates the rail has enabled
///                                              nothing.
///   · no fresh `/me` this session (offline)   → all off. See below.
///   · a foreground refresh that failed        → unchanged. See below.
///
/// ── Session state, never persisted ──
///
/// The server's own rule is "re-read rather than caching across sessions":
/// a flip propagates in ≤30s server-side, and a flag that outlives its launch
/// on disk is a kill switch that does not reach this phone until it next has
/// signal AND the cache is replaced. So this holds the map in memory only and
/// adopts it from a NETWORK answer only.
///
/// That is a real decision, because `/me` IS on disk: `CurrentUserStore.load`
/// goes through `CachedResource.loadShowingCacheFirst`, so the response bytes
/// — flags included — are in `ResponseCache` and are published first on the
/// next launch. Those bytes still serve the identity (which is what the cache
/// is there for: an offline launch must still know who records a spray), but
/// their flags are never adopted: `CurrentUserStore` hands this store only a
/// `.fresh` answer. An offline launch therefore runs with every flag off until
/// a launch with signal — failing closed, which for a dark-launch rail is the
/// only safe direction.
///
/// ── When a flip reaches the phone: the next return to the foreground ──
///
/// `/me` is read at launch and sign-in (`CurrentUserStore.load`, memoised for
/// the session) AND from the network on every return to the foreground
/// (`CurrentUserStore.refresh`, from `MainTabView`'s scenePhase handler) —
/// the owner's decision of 2026-10-02. Nothing polls while the app is open,
/// so the server's ≤30s is how fast a flip is SERVED, not how fast it lands
/// here: a running app picks it up the next time it comes to the foreground.
///
/// A refresh that FAILS (offline) keeps the map as it is rather than turning
/// it off. That differs from an offline cold launch on purpose: there the
/// session has no fresh answer, here it already holds one, and an
/// already-fresh value beats an unknown. See `CurrentUserStore.refresh`.
///
/// ── Reset on sign-out ──
///
/// Flags are resolved for A; B on the same phone must not see A's cohort. So
/// this joins `SessionReset.resetUserState()`, and `SignOutHygieneTests`'s
/// singleton guard holds it there.
@Observable
@MainActor
final class FeatureFlags {
    static let shared = FeatureFlags()

    /// The resolved map as last adopted. Read through `isOn`, which is the
    /// only correct reading of it for a DECISION. Админ → «Диагностика» lists
    /// its keys, because that readout's job is to show what the server sent,
    /// and still says "вкл." only where `isOn` would.
    private(set) var resolved: [String: Bool] = [:]

    /// When the map was last adopted — i.e. when the last FRESH `/me` was
    /// committed, since nothing else reaches `adopt` (`CurrentUserStore.commit`
    /// is the one call site, behind a `.fresh` check on both producers). nil:
    /// no fresh answer this session, which is also why every flag is off.
    ///
    /// For Админ → «Диагностика» and nothing else. It exists so the owner can
    /// time a flag flip on the server against its arrival on the phone — the
    /// propagation the foreground refresh was built for — without a debugger,
    /// in the Release build he actually runs. No decision may read it: "how
    /// old are the flags" has no correct threshold here, and the policy is
    /// already set (stale never adopted, a failed refresh keeps the last).
    ///
    /// Memory only, like `resolved`, and cleared with it: B's diagnostics must
    /// not show A's last answer as if it were B's.
    private(set) var lastFreshAt: Date?

    init() {}

    /// On only when the server sent this key, and sent it as `true`.
    func isOn(_ key: String) -> Bool { resolved[key] == true }

    /// Adopt the flags from a FRESH `/me`. `nil` is an older server with no
    /// `featureFlags` key, and means all off — not "keep what you had".
    ///
    /// The time is stamped HERE rather than by the caller, so the map and its
    /// stamp cannot be set apart; `now` is a parameter only so a test can
    /// hold the clock.
    func adopt(_ flags: [String: Bool]?, at now: Date = Date()) {
        resolved = flags ?? [:]
        lastFreshAt = now
    }

    /// Back to a fresh launch's state: everything off, no fresh answer yet.
    func reset() {
        resolved = [:]
        lastFreshAt = nil
    }
}
