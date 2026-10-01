import Foundation

/// Who is signed in.
///
/// ── Why this exists, and what it closes ──
///
/// The app knew its TOKENS and not its USER. That cost two things:
/// `assigneeUserId` on a field operation, which is `z.string().min(1)` —
/// required, not nullable — and the self-deactivation guard on the admin
/// screen, which had to fall back to the server's 403 after the tap.
///
/// Both were solvable only by reading the access token's claims, and
/// guessing which claim carries an id is exactly the kind of inference
/// this codebase has been bitten by repeatedly. `GET /api/auth/me` makes
/// the guess unnecessary.
///
/// ── `tenant` IS DELIBERATELY NOT MODELLED ──
///
/// The response carries `{ user, tenant }` and the tenant block is a trap:
/// it comes from `tenantMemberships` ordered `createdAt asc, take 1` — the
/// user's OLDEST membership, not the one they are currently looking at.
/// For a single-tenant user those coincide; for anyone else they do not,
/// and code that reached for `me.tenant.slug` to decide which farm it was
/// in would be right until the first person joined a second one.
///
/// Leaving it out is stronger than a comment saying not to use it. The
/// field this app needs is `user.id`, which is always correct. The tenant
/// comes from `Config.tenantSlug`, as it always has.
///
/// ── The path carries no tenant slug ──
///
/// So it sits outside the operator lockdown and a MECHANISATOR can call
/// it — which matters, because that persona is blocked from
/// `/users/assignable` and self-assignment is the only assignment they
/// can express.
struct CurrentUser: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let email: String?

    /// The role on the user's OLDEST membership — same caveat as the
    /// tenant block, and it is NOT a permission decision. It is used only
    /// to decide whether to OFFER an affordance.
    let role: String?

    /// The saved bottom-row order, or nil when never chosen.
    ///
    /// nil and `[]` are DIFFERENT and the column is nullable to keep them
    /// so: "never chose" draws the default, "deliberately cleared" does
    /// not. Collapsing them is unrecoverable.
    ///
    /// Nested inside `user`, beside `role` — confirmed by the server
    /// side after this was first written against a deployment that did
    /// not yet have the column. The earlier version read both here and
    /// at the envelope root, because a probe could only show where the
    /// field was NOT, and guessing wrong would have decoded nil forever
    /// rather than failing: a save that silently never persists. With the
    /// location known, the second read is noise.
    let bottomTabOrder: [String]?

    /// Runtime feature flags as the server resolved them for this caller
    /// (agri-saas#1209) — at the ENVELOPE root, beside `user`, not inside it.
    ///
    /// DO NOT READ THIS FOR A DECISION; read `FeatureFlags.shared.isOn`. This
    /// value may have come from the on-disk copy of `/me` (cache-first), and
    /// flags must not outlive their launch. `CurrentUserStore` hands only a
    /// FRESH answer's flags to `FeatureFlags`; see that type for why.
    ///
    /// Optional, and decoded with `try?`, although the #1209 spec makes it
    /// `required`: an older server omits it (= all off), and a map this build
    /// cannot read must cost the flags, never the identity — `/me` failing to
    /// decode would leave the spray sheet with no `assigneeUserId`.
    /// `DecoderToleranceTests` holds `CurrentUser` to requiring `user` only.
    let featureFlags: [String: Bool]?

    private enum Outer: String, CodingKey { case user, featureFlags }
    private enum Inner: String, CodingKey { case id, name, email, role, bottomTabOrder }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let user = try outer.nestedContainer(keyedBy: Inner.self, forKey: .user)
        self.id = try user.decode(String.self, forKey: .id)
        self.name = try user.decodeIfPresent(String.self, forKey: .name)
        self.email = try user.decodeIfPresent(String.self, forKey: .email)
        self.role = try user.decodeIfPresent(String.self, forKey: .role)
        self.bottomTabOrder = try user.decodeIfPresent([String].self, forKey: .bottomTabOrder)
        self.featureFlags = (try? outer.decodeIfPresent([String: Bool].self, forKey: .featureFlags)) ?? nil
    }

    /// May this person create a field operation?
    ///
    /// ── This gates an AFFORDANCE, never an action ──
    ///
    /// The server decides: `createFieldOperation` calls `assertCanWrite`,
    /// and `canWrite` is `ROLE_ORDER >= 3`. MECHANISATOR is 1, so an
    /// operator cannot create one — their job is COMPLETION, not creation
    /// (`/my-work`, marking assigned parcels done). The path allowlist
    /// letting `/locations/:id/operations` through is not the same as the
    /// write succeeding; there are two gates and this is the second.
    ///
    /// ── FAILS OPEN, deliberately ──
    ///
    /// `role` comes from the OLDEST membership, so for anyone in two
    /// tenants it may not be their role HERE. An unrecognised or absent
    /// role therefore shows the control and lets the server refuse.
    ///
    /// Hiding a button from somebody who could have used it is worse than
    /// showing one that might be refused: the refusal is a sentence they
    /// can read and report, the absence is a feature they conclude does
    /// not exist. The server is the authority either way, and its refusal
    /// is rendered.
    /// A MECHANISATOR, as far as the OLDEST membership knows.
    ///
    /// `isOperatorAllowedPath` in the server's `guard.ts` is a middleware
    /// lockdown, not presentation: anything under `/api/t/{slug}/` outside
    /// `farm-tasks|field-operations|tasks|locations|agro` returns 403
    /// `operator_scope` for this role. So a tab whose screen calls
    /// anything else is not a tab this person has — it is a tab that
    /// errors.
    ///
    /// Only MECHANISATOR. READER and AUDITOR are refused *writes* by
    /// `mayCreateOperations`, and whether the same path lockdown applies
    /// to them is not something this app has been told. Extending a rule
    /// past what was verified is how a screen gets taken away from
    /// somebody who could have used it.
    var isOperator: Bool { role?.uppercased() == "MECHANISATOR" }

    var mayCreateOperations: Bool { mayWrite }

    /// The server's `canWrite` — `ROLE_ORDER >= 3` — as far as the OLDEST
    /// membership knows, failing open for the reasons above.
    ///
    /// Named for what it is rather than for the first screen that needed it:
    /// exchange messaging gates the same way (open, send, close, block,
    /// unblock and retract are `assertCanWrite`; reading and marking read are
    /// `assertCanRead`), and a second copy of this list would be a second
    /// place for a new role to be forgotten.
    var mayWrite: Bool {
        switch role?.uppercased() {
        case "MECHANISATOR", "READER", "AUDITOR": false
        default: true
        }
    }

    init(id: String, name: String?, email: String?, role: String?,
         bottomTabOrder: [String]? = nil, featureFlags: [String: Bool]? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.bottomTabOrder = bottomTabOrder
        self.featureFlags = featureFlags
    }
}

enum MeAPI {
    /// No tenant slug in the path, deliberately — see `CurrentUser`.
    static let path = "/api/auth/me"

    static func decode(from data: Data) async throws -> CurrentUser {
        try await APIClient.shared.decode(data, as: CurrentUser.self)
    }
}

/// Cached for the session, because identity does not change under an
/// operator mid-spray.
///
/// It IS through `ResponseCache` (see `load()` — the 15-second offline launch
/// is why), scoped to the user by `CacheScope` and purged at Изход. That
/// matters for `featureFlags`, which ride in the same bytes: only a FRESH
/// answer's flags reach `FeatureFlags`, so a cached `/me` serves the identity
/// across launches and never the flags.
@Observable
@MainActor
final class CurrentUserStore {
    static let shared = CurrentUserStore()

    private(set) var user: CurrentUser?
    private var inFlight: Task<CurrentUser?, Never>?

    /// Who is signed in — from cache first, like every other read.
    ///
    /// ── The only uncached read in the app, and it cost 15 seconds ──
    ///
    /// This went straight to `APIClient.data(for:)`. Offline that waits out
    /// the request timeout before returning nil, and it is the FIRST thing
    /// `MainTabView.task` awaits — so the whole app sat behind it on every
    /// cold launch with no signal. Measured on a real phone: 15.8 seconds
    /// from the task starting to anything else happening.
    ///
    /// It gates more than startup. `ParcelOperationSheet.canSave` requires
    /// a known user, so across a fresh launch in a field a farmer could not
    /// have recorded a spray at all — the offline outbox depended on an
    /// identity the app refused to remember.
    ///
    /// The in-memory `user` is kept for the session; the cache is what
    /// survives a launch. Both are needed: the first avoids a round trip
    /// per caller, the second avoids a network round trip per launch.
    func load() async -> CurrentUser? {
        if let user { return user }
        if let inFlight { return await inFlight.value }

        // ── A `/me` that answers after Изход is not anybody's ──
        //
        // Started under A, resolved after A signed out: writing it to `user`
        // would hand B A's identity — the field operation's `assigneeUserId`,
        // the operator flag, the outbox's owner. So the epoch is captured
        // here and the result is dropped if it has moved.
        let epoch = SessionEpoch.current
        let task = Task<CurrentUser?, Never> {
            var resolved: CurrentUser?
            // The flags from a NETWORK answer only. `.loaded(_, .fresh)` is
            // what `CachedResource.load` returns for a 200 (the app sends no
            // `If-None-Match`, so a 304 does not arise); the cache-first
            // publish and the offline fallback are both `.stale`. Stale
            // flags are a kill switch that did not reach this phone, so they
            // are never adopted — see `FeatureFlags`.
            var freshFlags: [String: Bool]??
            await CachedResource.loadShowingCacheFirst(MeAPI.path) { data in
                try await MeAPI.decode(from: data)
            } publish: { state in
                // Cache first, then the network answer if it differs. The
                // LAST publish wins, which is the fresh one when there is
                // a network and the cached one when there is not.
                if let value = state.value { resolved = value }
                if case .loaded(let value, .fresh) = state { freshFlags = .some(value.featureFlags) }
            }
            // `clear()` already let go of this task; touching `inFlight` now
            // could release a NEWER session's request instead.
            guard SessionEpoch.isCurrent(epoch) else { return nil }
            inFlight = nil
            if let resolved {
                // The identity everything per-user is keyed on — the response
                // cache and the outbox's owner. Adopted from the SERVER's
                // answer, never from anything on disk that preceded it.
                SessionIdentity.shared.adopt(resolved.id)
            } else {
                Log.auth.error("could not resolve current user, cached or live")
            }
            user = resolved
            // Outer nil: no fresh answer, keep what the session has (all off
            // at launch). Inner nil: a fresh answer from a server with no
            // `featureFlags` key, which `adopt` reads as all off.
            if let freshFlags { FeatureFlags.shared.adopt(freshFlags) }
            return resolved
        }
        inFlight = task
        return await task.value
    }

    /// Back to a fresh launch's state — part of `SessionReset`. The request
    /// in flight is let go rather than cancelled: it may be the same one a
    /// caller is awaiting, and the epoch guard above already discards it.
    func clear() {
        user = nil
        inFlight = nil
    }

    #if DEBUG
    /// For `SignOutHygieneTests`, which needs A signed in without a network.
    func adoptForTesting(_ user: CurrentUser) { self.user = user }
    #endif
}
