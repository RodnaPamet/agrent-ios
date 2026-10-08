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
/// ── `tenant` is WHERE A FIRST SIGN-IN STARTS, and nothing more ──
///
/// The response carries `{ user, tenant }` and the tenant block is a trap:
/// it comes from `tenantMemberships` ordered `createdAt asc, take 1` — the
/// user's OLDEST membership, not the one they are currently looking at.
/// For a single-tenant user those coincide; for anyone else they do not.
///
/// It was left out for that reason until farms stopped being pinned
/// (agrent-ios#179). It is read in ONE place: `FarmStore.resolve`, for a
/// person with no farm remembered on this phone — where the oldest
/// membership is a fair place to start and nil means "no farm yet". Which
/// farm is open is `FarmStore`'s answer, never this field's.
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

    /// The account's picture, AS STORED on the server (agri-saas#1299/#1316),
    /// or nil for none — the account card then draws initials and asks
    /// nothing. A straight projection of `User.image`, in one of two shapes
    /// that are fetched differently; `AccountAvatarAPI.source` tells them
    /// apart and says why it matters (whose credentials go where).
    ///
    /// Optional AND decoded with `try?`: the spec does not require it, a
    /// server older than the field omits it (absent = null, never a third
    /// state), and a value this build cannot read must cost the picture,
    /// never the identity the spray sheet needs.
    let avatarUrl: String?

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

    /// The person's OLDEST membership, or nil for a person with no farm —
    /// see the header for the one place it is read.
    let tenant: Tenant?

    struct Tenant: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let slug: String
    }

    private enum Outer: String, CodingKey { case user, featureFlags, tenant }
    private enum Inner: String, CodingKey { case id, name, email, role, bottomTabOrder, avatarUrl }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let user = try outer.nestedContainer(keyedBy: Inner.self, forKey: .user)
        self.id = try user.decode(String.self, forKey: .id)
        self.name = try user.decodeIfPresent(String.self, forKey: .name)
        self.email = try user.decodeIfPresent(String.self, forKey: .email)
        self.role = try user.decodeIfPresent(String.self, forKey: .role)
        self.bottomTabOrder = try user.decodeIfPresent([String].self, forKey: .bottomTabOrder)
        self.avatarUrl = (try? user.decodeIfPresent(String.self, forKey: .avatarUrl)) ?? nil
        self.featureFlags = (try? outer.decodeIfPresent([String: Bool].self, forKey: .featureFlags)) ?? nil
        // Lenient like the flags: a tenant block that will not decode costs a
        // first sign-in its starting farm (it is asked to choose), never the
        // identity every other screen needs.
        self.tenant = (try? outer.decodeIfPresent(Tenant.self, forKey: .tenant)) ?? nil
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
         bottomTabOrder: [String]? = nil, featureFlags: [String: Bool]? = nil,
         avatarUrl: String? = nil, tenant: Tenant? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.bottomTabOrder = bottomTabOrder
        self.featureFlags = featureFlags
        self.avatarUrl = avatarUrl
        self.tenant = tenant
    }
}

enum MeAPI {
    /// No tenant slug in the path, deliberately — see `CurrentUser`.
    static let path = "/api/auth/me"

    static func decode(from data: Data) async throws -> CurrentUser {
        try await APIClient.shared.decode(data, as: CurrentUser.self)
    }
}

/// Held for the session — identity does not change under an operator
/// mid-spray — and re-read from the network every time the app returns to
/// the foreground (`refresh()`, owner decision 2026-10-02).
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
    /// ONE slot for `load()` and `refresh()` alike: whichever started first is
    /// the request, and the other awaits it. Two slots would mean two `/me`s
    /// racing to write `user` and the flags, and the later ANSWER — not the
    /// later request — would win.
    @ObservationIgnored private var inFlight: Task<CurrentUser?, Never>?

    /// Seams for `CurrentUserRefreshTests`: the two producers of `/me` — the
    /// cache-first one `load()` uses and the network-only one `refresh()`
    /// uses — and where a resolved answer is adopted. The app uses the real
    /// five. Tabs is a closure rather than a store because `BottomTabsStore`
    /// has a private init and no second instance to hand in.
    ///
    /// BOTH producers are seams, and that is what lets a test COUNT: every
    /// `/api/auth/me` this app sends is one call of one of these two closures
    /// (a source guard holds `MeAPI.path` to this file), so a fake that counts
    /// its calls counts the requests a launch or a foreground would send.
    @ObservationIgnored private let fetchCacheFirst: @MainActor () async -> Resolution
    @ObservationIgnored private let fetchFresh: @MainActor () async -> LoadState<CurrentUser>
    @ObservationIgnored private let identity: SessionIdentity
    @ObservationIgnored private let flags: FeatureFlags
    @ObservationIgnored private let adoptTabs: @MainActor (CurrentUser) -> Void

    /// What the cache-first read settled on: the user from the LAST publish
    /// that carried one (the network's when there is a network, the disk's
    /// when there is not), and the flags from a `.fresh` publish only.
    ///
    /// `freshFlags` — outer nil: no network answer arrived, so no flags may be
    /// adopted. Inner nil: a fresh answer from a server with no `featureFlags`
    /// key. See `commit`.
    struct Resolution {
        var user: CurrentUser?
        var freshFlags: [String: Bool]??
    }

    /// The real cache-first `/me`: published from disk first, then the network.
    ///
    /// The flags from a NETWORK answer only. `.loaded(_, .fresh)` is what
    /// `CachedResource.load` returns for a 200 (the app sends no
    /// `If-None-Match`, so a 304 does not arise); the cache-first publish and
    /// the offline fallback are both `.stale`. Stale flags are a kill switch
    /// that did not reach this phone, so they are never adopted — see
    /// `FeatureFlags`.
    @MainActor
    static func resolveCacheFirst() async -> Resolution {
        var resolution = Resolution()
        await CachedResource.loadShowingCacheFirst(MeAPI.path) { data in
            try await MeAPI.decode(from: data)
        } publish: { state in
            // Cache first, then the network answer if it differs. The LAST
            // publish wins, which is the fresh one when there is a network
            // and the cached one when there is not.
            if let value = state.value { resolution.user = value }
            if case .loaded(let value, .fresh) = state { resolution.freshFlags = .some(value.featureFlags) }
        }
        return resolution
    }

    init(
        fetchCacheFirst: @escaping @MainActor () async -> Resolution = {
            await CurrentUserStore.resolveCacheFirst()
        },
        fetchFresh: @escaping @MainActor () async -> LoadState<CurrentUser> = {
            await CachedResource.load(MeAPI.path) { data in try await MeAPI.decode(from: data) }
        },
        identity: SessionIdentity = .shared,
        // nil-then-`.shared` in the body rather than a `= .shared` default: a
        // default argument is evaluated outside the main actor, and
        // `FeatureFlags.shared` is main-actor state.
        flags: FeatureFlags? = nil,
        adoptTabs: @escaping @MainActor (CurrentUser) -> Void = {
            BottomTabsStore.shared.adopt($0.bottomTabOrder, isOperator: $0.isOperator)
        }
    ) {
        self.fetchCacheFirst = fetchCacheFirst
        self.fetchFresh = fetchFresh
        self.identity = identity
        self.flags = flags ?? FeatureFlags.shared
        self.adoptTabs = adoptTabs
    }

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
            let resolution = await fetchCacheFirst()
            let resolved = resolution.user
            // `clear()` already let go of this task; touching `inFlight` now
            // could release a NEWER session's request instead.
            guard SessionEpoch.isCurrent(epoch) else { return nil }
            inFlight = nil
            if resolved == nil {
                Log.auth.error("could not resolve current user, cached or live")
            }
            commit(resolved, freshFlags: resolution.freshFlags)
            return resolved
        }
        inFlight = task
        return await task.value
    }

    /// Re-read `/me` from the NETWORK, past the session memo, every time the
    /// app returns to the foreground (owner decision 2026-10-02) — so a flag
    /// flip, a role change or a bar saved on the web reaches a running app
    /// the next time it is opened, not at its next cold launch. Never on a
    /// timer while open: the owner chose that over a request every 30 s from
    /// a phone in a field.
    ///
    /// ── Coalesced with whatever `/me` is already in flight ──
    ///
    /// A `load()` in flight reads the network too (cache first, THEN the
    /// network), so its answer is as fresh as this one would be and a second
    /// request would only race it to `user`. Its result is returned as is.
    ///
    /// ── A failure changes NOTHING — unlike a cold offline launch ──
    ///
    /// A launch with no signal runs with every flag off: it has no fresh
    /// answer at all, and the cached one may predate a kill switch. Here the
    /// session already HOLDS a fresh answer (from launch or an earlier
    /// foreground), and a refresh that cannot reach the server has learned
    /// nothing that contradicts it — an already-fresh value beats an unknown.
    /// Flipping flags off on failure would make a surface vanish whenever a
    /// farmer opens the app at the edge of a field and come back when they
    /// walk in. If the session never had a fresh answer its flags are still
    /// all off, so keeping them keeps that too.
    ///
    /// The user is kept for the same reason, and because the spray sheet
    /// needs an identity to record offline.
    @discardableResult
    func refresh() async -> CurrentUser? {
        if let inFlight { return await inFlight.value }

        // The same guard as `load()`: an answer for A that lands after Изход
        // is dropped, flags and all — B must not open on A's cohort.
        let epoch = SessionEpoch.current
        let task = Task<CurrentUser?, Never> {
            let answer = await fetchFresh()
            guard SessionEpoch.isCurrent(epoch) else { return nil }
            inFlight = nil
            // `.fresh` only. `CachedResource.load` gives nothing else for a
            // 200; a `.stale` here would be a disk copy, and flags are never
            // adopted from one.
            guard case .loaded(let fresh, .fresh) = answer else {
                Log.auth.info("foreground /me refresh failed; keeping the session's user and flags")
                return user
            }
            commit(fresh, freshFlags: .some(fresh.featureFlags))
            return fresh
        }
        inFlight = task
        return await task.value
    }

    /// Who is signed in, as far as a `/me` ALREADY ASKED will say — never a
    /// request of its own. For `OfflinePrefetch`, and for nothing that needs
    /// an answer when there is none.
    ///
    /// ── Why the prefetch must not ask ──
    ///
    /// It used to: `CachedResource.load(MeAPI.path)` straight, past this
    /// store. It runs at the two moments this store is ALREADY asking — the
    /// launch task's `load()` and the foreground handler's `refresh()`, in
    /// the same handler — so every foreground sent `/me` twice, and every
    /// cold launch too. Two answers, only one of which reached `user` and the
    /// flags; the other wrote the cache and was thrown away.
    ///
    /// What the prefetch wanted from it was the CACHE ENTRY, so a cold launch
    /// in a field has an identity. Both of this store's producers write
    /// `ResponseCache` on a 200 (`CachedResource.load` does, under both), so
    /// the entry is written by the request that is happening anyway.
    ///
    /// ── Why not `load()` ──
    ///
    /// `load()` starts a request when there is no user and none in flight —
    /// which is exactly the offline launch, where it would send a second
    /// `/me` into the same dead link. This one waits for a request in flight
    /// (so the prefetch's own writes land under the identity that answer
    /// adopts) and otherwise returns what is held, nil included.
    func settled() async -> CurrentUser? {
        if let inFlight { return await inFlight.value }
        return user
    }

    /// The one place a resolved `/me` is adopted, by both paths, and only
    /// AFTER each has checked the epoch.
    ///
    /// `freshFlags` — outer nil: no fresh answer, keep what the session has
    /// (all off at launch). Inner nil: a fresh answer from a server with no
    /// `featureFlags` key, which `adopt` reads as all off.
    private func commit(_ resolved: CurrentUser?, freshFlags: [String: Bool]??) {
        if let resolved {
            // The identity everything per-user is keyed on — the response
            // cache and the outbox's owner. Adopted from the SERVER's
            // answer, never from anything on disk that preceded it.
            identity.adopt(resolved.id)
            // The bar, HERE rather than after `load()` in `MainTabView.task`
            // where it used to be: a refresh needs it too, and so does a
            // `load()` another screen started that the launch coalesced
            // onto. Same answer, same moment, one place.
            adoptTabs(resolved)
        }
        user = resolved
        if let freshFlags { flags.adopt(freshFlags) }
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
