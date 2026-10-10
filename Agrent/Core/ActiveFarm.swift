import Foundation
import Observation

/// One of the signed-in person's farms, as far as the app needs to know it:
/// the slug every path is built with, the name a person reads, and what this
/// person may do there.
struct Farm: Codable, Equatable, Hashable, Sendable {
    let slug: String
    /// nil when the farm is known only by its slug — the legacy farm seeded
    /// for people signed in before #179 — until `/me` or the farm list says.
    let name: String?
    /// This person's role IN THIS FARM (`OWNER`, `MECHANISATOR`, …), or nil
    /// until the farm list or `/me` has said. A string, as the spec has it: a
    /// growing union.
    ///
    /// Remembered with the farm, so a launch with no signal gates each screen
    /// on the role it had last time rather than on the OLDEST membership's;
    /// the next list read corrects it. A farm remembered before stage 3 has
    /// no `role` key and decodes as nil.
    let role: String?
    /// The platform farm: the one whose admins type the daily prices every
    /// farm sees (#258, agri-saas #1587 v1.1). From the farm list's own row,
    /// because `/api/auth/me` answers for the OLDEST membership and would say
    /// no while this farm is open. It decides only what to OFFER; the server
    /// checks on every request. nil until the list has said, and on a farm
    /// remembered before it said: no.
    let isPlatform: Bool?

    init(slug: String, name: String?, role: String? = nil, isPlatform: Bool? = nil) {
        self.slug = slug
        self.name = name
        self.role = role
        self.isPlatform = isPlatform
    }

    init(_ membership: FarmsAPI.Membership) {
        self.init(slug: membership.slug, name: membership.name, role: membership.role,
                  isPlatform: membership.isPlatform)
    }

    /// Whether to offer Админ → «Цени»: the platform farm, to its owner or
    /// an admin. The same pair the routes' `admin.manage` resolves from.
    var offersPlatformPrices: Bool {
        isPlatform == true && (role == "OWNER" || role == "ADMIN")
    }
}

/// The ACTIVE farm, readable from any thread (agrent-ios#179).
///
/// ── A lock-protected mirror, and why ──
///
/// Paths are built from nonisolated code — `APIClient`, `CachedResource`,
/// `CacheScope`, the outbox's replay — which is why `SessionIdentity` is a
/// lock-protected mirror too. An `await` on every path would put a suspension
/// point in the middle of decisions that must be atomic with the request.
/// `FarmStore` is the ONE writer; everything else reads it through `FarmPath`.
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

    func farm(for userID: String) -> Farm? {
        guard let data = defaults.data(forKey: Self.key(userID)) else { return nil }
        return try? JSONDecoder().decode(Farm.self, from: data)
    }

    func remember(_ farm: Farm, for userID: String) {
        guard let data = try? JSONEncoder().encode(farm) else { return }
        defaults.set(data, forKey: Self.key(userID))
    }

    /// The remembered farm is no longer this person's, and there is none to
    /// remember instead.
    func forget(for userID: String) {
        defaults.removeObject(forKey: Self.key(userID))
    }

    // ── No seed any more (agrent-ios#192) ──
    //
    // #179 seeded the pinned farm, once per install, for whoever was signed
    // in when that build first ran, so nobody's screen switched under them
    // on the update. It ran on the one install there was, the owner's phone,
    // which has remembered its farm since. Kept, it was the last way onto a
    // farm the person never chose: `UserDefaults` goes with the app and the
    // Keychain's session does not, so a reinstall seeded the pinned farm for
    // whoever was still signed in — member of it or not. A fresh install now
    // starts where a first sign-in does: `/me`'s farm.
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
/// ── Then the farm list squares it with the server (stage 3) ──
///
/// `GET /api/me/farms` is read once a farm is settled, on every return to
/// the app, and when Профил opens. It is what Профил lists, it says this
/// person's role in the open farm, and it is the one thing that CLOSES a
/// farm: the spec says a farm absent from it is "unreachable, not merely
/// unlisted", and a remembered farm the person was removed from would
/// otherwise open on every launch into 403s on every screen.
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
        /// `/me` says this person belongs to no farm — or the farm list no
        /// longer has the one that was open, and has no other.
        case none
        /// Nothing remembered and `/me` could not be read — offline on a
        /// first sign-in.
        case failed
    }

    private(set) var state: State = .resolving

    /// Every farm this person belongs to, oldest first, as the server listed
    /// them THIS SESSION — Профил's list. nil until a list has been read, and
    /// never on disk: see `FarmsAPI.farms`.
    private(set) var farms: [Farm]?

    /// The last attempt to read the list failed. Профил says so under the
    /// farm it can still show, the open one.
    private(set) var listUnavailable = false

    /// A farm this store CLOSED because the list no longer has it — the
    /// person was removed from it, or the farm was removed. `FarmGate` says
    /// so, once: without a word the app would just open another farm, which
    /// reads as this one's records vanishing.
    private(set) var lostAccess: Farm?

    /// The open farm, when there is one.
    var activeFarm: Farm? {
        if case .active(let farm) = state { return farm }
        return nil
    }

    @ObservationIgnored private let identity: SessionIdentity
    @ObservationIgnored private let memory: FarmMemory
    @ObservationIgnored private let mirror: ActiveFarm
    @ObservationIgnored private let loadMe: @MainActor () async -> CurrentUser?
    @ObservationIgnored private let loadFarms: @MainActor () async throws -> [FarmsAPI.Membership]
    @ObservationIgnored private let onFarmChange: @MainActor () -> Void
    @ObservationIgnored private let adoptRole: @MainActor (String?) -> Void

    /// False under the UI-test seam, which never writes a person's memory.
    @ObservationIgnored private var remembers = true

    /// ONE list request at a time: a second caller awaits the first rather
    /// than racing it to `farms`.
    @ObservationIgnored private var listing: Task<Void, Never>?

    /// Counts the farms the PERSON has opened — from Профил, or one they have
    /// just created. A list asked for before such a choice may predate it: a
    /// list from before a farm was created does not have that farm, and must
    /// not close it. So an answer is only acted on if no choice was made
    /// while it was on its way; otherwise the list is asked for again.
    @ObservationIgnored private var choices = 0

    init(
        identity: SessionIdentity = .shared,
        memory: FarmMemory = FarmMemory(defaults: .standard),
        mirror: ActiveFarm = .shared,
        loadMe: @escaping @MainActor () async -> CurrentUser? = { await CurrentUserStore.shared.load() },
        loadFarms: @escaping @MainActor () async throws -> [FarmsAPI.Membership] = { try await FarmsAPI.farms() },
        onFarmChange: @escaping @MainActor () -> Void = { FarmStore.resetFarmState() },
        adoptRole: @escaping @MainActor (String?) -> Void = { CurrentUserStore.shared.adoptRoleHere($0) }
    ) {
        self.identity = identity
        self.memory = memory
        self.mirror = mirror
        self.loadMe = loadMe
        self.loadFarms = loadFarms
        self.onFarmChange = onFarmChange
        self.adoptRole = adoptRole
        #if DEBUG
        // The fixture world is one farm, the one every fixture path was
        // recorded under; the seam never reads or writes a person's memory.
        if UITestSeam.isActive {
            remembers = false
            activate(Farm(slug: Config.pinnedFarmSlug, name: nil), remember: false)
            return
        }
        #endif
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
        if openFromList() { return }

        guard let me = await loadMe() else {
            state = .failed
            return
        }
        // `/me` has told `SessionIdentity` who this is, so a farm this person
        // chose before on this phone can be found now — and wins over `/me`'s
        // oldest membership, which is only where a first sign-in starts.
        restoreRemembered()
        if case .active = state { return }
        if openFromList() { return }
        if let tenant = me.tenant {
            // `/me`'s role is the role on that SAME membership — one row,
            // `take: 1`, read for both — so the first farm opens with the
            // right one before any list has been read.
            activate(Farm(slug: tenant.slug, name: tenant.name, role: me.role))
        } else {
            state = .none
        }
    }

    /// THE LIST OVER `/me`, once the list has answered this session. `/me`
    /// in memory can still name a farm the list has since closed — it is
    /// re-read only on a return to the app — and opening that farm here
    /// would undo the close the list just made. The list's first is the
    /// oldest membership, the farm `/me` names when it is current.
    private func openFromList() -> Bool {
        guard let farms else { return false }
        if let first = farms.first { activate(first) } else { state = .none }
        return true
    }

    /// Open `farm`, and remember it as this person's choice.
    func activate(_ farm: Farm, remember: Bool = true) {
        let previous = mirror.farm
        mirror.set(farm)
        if remember, remembers, let userID = identity.userID {
            memory.remember(farm, for: userID)
        }
        if let previous, previous.slug != farm.slug {
            onFarmChange()
        }
        // Before the state moves, so the tabs `FarmGate` builds for this farm
        // are built on this farm's role.
        adoptRole(farm.role)
        state = .active(farm)
    }

    /// The person opens one of their farms — from Профил's list.
    func open(_ farm: Farm) {
        choices += 1
        activate(farm)
    }

    /// A farm this person has just CREATED: open it, and read the list again
    /// so Профил has it.
    func openCreated(_ farm: Farm) {
        open(farm)
        Task { await refreshFarms() }
    }

    /// The open farm's NAME, when `/me` reports the same farm with one.
    ///
    /// The legacy farm is seeded by slug alone, and the menu would show the
    /// slug until something names it. Only the name: a different farm in
    /// `/me` is the person's OLDEST membership, not a reason to switch.
    func adoptName(from tenant: CurrentUser.Tenant?) {
        guard let tenant, let farm = activeFarm, farm.slug == tenant.slug,
              farm.name != tenant.name else { return }
        activate(Farm(slug: farm.slug, name: tenant.name, role: farm.role, isPlatform: farm.isPlatform))
    }

    /// Read this person's farms, and square the open farm with them.
    ///
    /// A list that cannot be read changes NOTHING but `listUnavailable`:
    /// offline, the open farm and its remembered role carry on, which is what
    /// a farmer in a field needs from it.
    func refreshFarms() async {
        if let listing { return await listing.value }
        let epoch = SessionEpoch.current
        let task = Task<Void, Never> {
            var answer: [FarmsAPI.Membership]?
            var choice: Int
            repeat {
                choice = choices
                do {
                    answer = try await loadFarms()
                } catch {
                    Log.auth.info("farm list unavailable; keeping the open farm")
                    answer = nil
                }
                // `reset()` already let go of this task; touching `listing`
                // now could release a NEWER session's request instead.
                guard SessionEpoch.isCurrent(epoch) else { return }
            } while answer != nil && choice != choices
            listing = nil
            guard let answer else {
                listUnavailable = true
                return
            }
            listUnavailable = false
            adopt(answer.map { Farm($0) })
        }
        listing = task
        await task.value
    }

    /// The list as the server has it NOW. The one place a farm is closed for
    /// no longer being this person's — and where a person with none, or
    /// whose first sign-in could not reach `/me`, is given the one they now
    /// have: invited on the web while this phone said «Нямате стопанство»,
    /// they would otherwise have to relaunch to be let in — or, with the
    /// wizard on that screen, create a second farm instead.
    private func adopt(_ list: [Farm]) {
        farms = list
        let open: Farm
        switch state {
        case .active(let farm):
            open = farm
        case .none, .failed:
            if let first = list.first { activate(first) }
            return
        case .resolving:
            // `resolve()` is on its way, and reads this list when it lands.
            return
        }
        if let listed = list.first(where: { $0.slug == open.slug }) {
            // Still theirs: the server's name for it, and their role there.
            // The same slug, so nothing is rebuilt.
            if listed != open { activate(listed) }
            return
        }
        lostAccess = open
        if let next = list.first {
            // The oldest membership, which is where a first sign-in starts.
            activate(next)
        } else {
            if remembers, let userID = identity.userID {
                memory.forget(for: userID)
            }
            mirror.set(nil)
            onFarmChange()
            adoptRole(nil)
            state = .none
        }
    }

    /// `FarmGate` has said that a farm was closed.
    func acknowledgeLostAccess() {
        lostAccess = nil
    }

    /// Изход: no farm is open for whoever signs in next. The remembered
    /// choice stays with its person, for when they come back.
    func reset() {
        mirror.set(nil)
        adoptRole(nil)
        state = .resolving
        farms = nil
        listUnavailable = false
        lostAccess = nil
        // Let go rather than cancelled, as `/me`'s is: the epoch guard
        // discards whatever it answers.
        listing = nil
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
