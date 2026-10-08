import Foundation
import Observation

/// One of the signed-in person's farms, as far as the app needs to know it:
/// the slug every path is built with, and the name a person reads.
struct Farm: Codable, Equatable, Hashable, Sendable {
    let slug: String
    /// nil when the farm is known only by its slug — the legacy farm seeded
    /// for people signed in before #179 — until `/me` or the farm list says.
    let name: String?
}

/// The ACTIVE farm, readable from any thread (agrent-ios#179).
///
/// ── A lock-protected mirror, and why ──
///
/// Paths are built from nonisolated code — `APIClient`, `CachedResource`,
/// `CacheScope`, the outbox's replay — which is why `SessionIdentity` is a
/// lock-protected mirror too. An `await` on every path would put a suspension
/// point in the middle of decisions that must be atomic with the request.
/// `FarmStore` is the ONE writer; everything else reads `Config.tenantSlug`.
final class ActiveFarm: @unchecked Sendable {
    static let shared = ActiveFarm()

    private let lock = NSLock()
    private var current: Farm?

    var farm: Farm? { lock.withLock { current } }

    func set(_ farm: Farm?) { lock.withLock { current = farm } }
}

/// Which farm each person last had open, on this phone.
///
/// PER PERSON, not per phone: a shared phone opens each person's own farm,
/// and a sign-out keeps the choice for when they sign back in. Not secret —
/// a slug is in every URL — so `UserDefaults`, not the Keychain.
struct FarmMemory {
    let defaults: UserDefaults

    private static func key(_ userID: String) -> String { "farm.active.v1.\(userID)" }
    static let seededKey = "farm.legacySeeded.v1"

    func farm(for userID: String) -> Farm? {
        guard let data = defaults.data(forKey: Self.key(userID)) else { return nil }
        return try? JSONDecoder().decode(Farm.self, from: data)
    }

    func remember(_ farm: Farm, for userID: String) {
        guard let data = try? JSONEncoder().encode(farm) else { return }
        defaults.set(data, forKey: Self.key(userID))
    }

    /// ONCE PER INSTALL: whoever is signed in when this build first runs
    /// keeps the farm the app was pinned to.
    ///
    /// `/me`'s tenant is the person's OLDEST membership, which need not be
    /// the farm they have been using here — and a screen that switched farms
    /// under somebody on an update would read as their records vanishing.
    /// Nobody signed in, or a farm already remembered: nothing to keep.
    func seedLegacyFarmOnce(for userID: String?) {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        guard let userID, farm(for: userID) == nil else { return }
        remember(Farm(slug: Config.legacyTenantSlug, name: nil), for: userID)
    }
}

/// Which farm the app shows, decided before any of it is shown (#179).
///
/// ── The order ──
///
/// 1. The farm this person had open last, remembered on this phone —
///    SYNCHRONOUSLY, at launch, so a returning farmer waits on nothing. The
///    launch was made not to wait on `/me` (a 16-second timeout in a field,
///    measured), and this keeps it that way.
/// 2. Otherwise `/me`'s tenant — their oldest membership. Only a person with
///    nothing remembered gets here: a first sign-in on this phone, and they
///    have just been online to sign in.
/// 3. Otherwise no farm: `FarmGate` says so and offers the way on.
///
/// ── A change of farm is a change of everything shown ──
///
/// `FarmGate` gives the tab view a new identity per farm, so every screen's
/// own store is built afresh; the shared stores that hold a FARM's data are
/// reset here (`resetFarmState`). Queued records are not touched: each
/// carries the farm it was made on and goes there (`PendingOperation.tenant`).
@Observable
@MainActor
final class FarmStore {
    static let shared = FarmStore()

    enum State: Equatable {
        /// Nothing remembered for this person, and `/me` has not answered.
        case resolving
        case active(Farm)
        /// `/me` says this person belongs to no farm.
        case none
        /// Nothing remembered and `/me` could not be read — offline on a
        /// first sign-in.
        case failed
    }

    private(set) var state: State = .resolving

    /// The open farm, when there is one.
    var activeFarm: Farm? {
        if case .active(let farm) = state { return farm }
        return nil
    }

    @ObservationIgnored private let identity: SessionIdentity
    @ObservationIgnored private let memory: FarmMemory
    @ObservationIgnored private let mirror: ActiveFarm
    @ObservationIgnored private let loadMe: @MainActor () async -> CurrentUser?
    @ObservationIgnored private let onFarmChange: @MainActor () -> Void

    init(
        identity: SessionIdentity = .shared,
        memory: FarmMemory = FarmMemory(defaults: .standard),
        mirror: ActiveFarm = .shared,
        loadMe: @escaping @MainActor () async -> CurrentUser? = { await CurrentUserStore.shared.load() },
        onFarmChange: @escaping @MainActor () -> Void = { FarmStore.resetFarmState() }
    ) {
        self.identity = identity
        self.memory = memory
        self.mirror = mirror
        self.loadMe = loadMe
        self.onFarmChange = onFarmChange
        #if DEBUG
        // The fixture world is one farm, the one every fixture path was
        // recorded under; the seam never reads or writes a person's memory.
        if UITestSeam.isActive {
            activate(Farm(slug: Config.legacyTenantSlug, name: nil), remember: false)
            return
        }
        #endif
        memory.seedLegacyFarmOnce(for: identity.userID)
        restoreRemembered()
    }

    /// The farm this person had open last, if one is remembered — without a
    /// request. Called at launch and again once `/me` has said who they are.
    func restoreRemembered() {
        guard case .resolving = state,
              let userID = identity.userID,
              let farm = memory.farm(for: userID) else { return }
        activate(farm)
    }

    /// Settle which farm to show. Returns at once when one is already open.
    func resolve() async {
        if case .active = state { return }
        state = .resolving
        restoreRemembered()
        if case .active = state { return }

        guard let me = await loadMe() else {
            state = .failed
            return
        }
        // `/me` has told `SessionIdentity` who this is, so a farm this person
        // chose before on this phone can be found now — and wins over `/me`'s
        // oldest membership, which is only where a first sign-in starts.
        restoreRemembered()
        if case .active = state { return }
        if let tenant = me.tenant {
            activate(Farm(slug: tenant.slug, name: tenant.name))
        } else {
            state = .none
        }
    }

    /// Open `farm`, and remember it as this person's choice.
    func activate(_ farm: Farm, remember: Bool = true) {
        let previous = mirror.farm
        mirror.set(farm)
        if remember, let userID = identity.userID {
            memory.remember(farm, for: userID)
        }
        if let previous, previous.slug != farm.slug {
            onFarmChange()
        }
        state = .active(farm)
    }

    /// The open farm's NAME, when `/me` reports the same farm with one.
    ///
    /// The legacy farm is seeded by slug alone, and the menu would show the
    /// slug until something names it. Only the name: a different farm in
    /// `/me` is the person's OLDEST membership, not a reason to switch.
    func adoptName(from tenant: CurrentUser.Tenant?) {
        guard let tenant, let farm = activeFarm, farm.slug == tenant.slug,
              farm.name != tenant.name else { return }
        activate(Farm(slug: farm.slug, name: tenant.name))
    }

    /// Изход: no farm is open for whoever signs in next. The remembered
    /// choice stays with its person, for when they come back.
    func reset() {
        mirror.set(nil)
        state = .resolving
    }

    /// The shared stores that hold a FARM's data, rather than a person's.
    ///
    /// Each view's own store is rebuilt by `FarmGate` (a new identity per
    /// farm); these outlive views. The person's stores — `/me`, the bar,
    /// flags, the picture, the outbox — stay: the person did not change.
    static func resetFarmState() {
        ExchangeUnreadStore.shared.reset()
        RateLimitPause.messages.reset()
    }
}
