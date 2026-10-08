import XCTest
@testable import Agrent

/// Which farm the app opens, and where a queued record goes once farms can
/// change (agrent-ios#179). `FarmStore` is driven with its own identity,
/// memory, mirror and `/me` — nothing here touches the phone's real choice or
/// sends a request.
@MainActor
final class FarmStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test.farms.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func identity(_ userID: String?) -> SessionIdentity {
        SessionIdentity(load: { userID }, save: { _ in })
    }

    private func me(_ id: String, tenant: (slug: String, name: String)?) -> CurrentUser {
        CurrentUser(id: id, name: nil, email: nil, role: "OWNER",
                    tenant: tenant.map { .init(id: "ten_\($0.slug)", name: $0.name, slug: $0.slug) })
    }

    /// A store whose `/me` is `answer`, counting how often it is asked — and
    /// adopting the answer's id as the real store does, since `/me` is how a
    /// fresh sign-in learns who it is.
    private func store(
        identity: SessionIdentity, memory: FarmMemory? = nil, mirror: ActiveFarm = ActiveFarm(),
        answer: CurrentUser?, asked: (() -> Void)? = nil, changed: (() -> Void)? = nil
    ) -> FarmStore {
        FarmStore(
            identity: identity,
            memory: memory ?? FarmMemory(defaults: defaults),
            mirror: mirror,
            loadMe: {
                asked?()
                if let answer { identity.adopt(answer.id) }
                return answer
            },
            onFarmChange: { changed?() })
    }

    // MARK: - The order

    /// A returning person's farm is open before the first frame, and `/me`
    /// is not asked for it — the launch waits on nothing.
    func testARememberedFarmOpensWithoutAsking() async {
        let memory = FarmMemory(defaults: defaults)
        defaults.set(true, forKey: FarmMemory.seededKey)
        memory.remember(Farm(slug: "ferma-2", name: "Ферма 2"), for: "usr_a")
        var asks = 0
        let mirror = ActiveFarm()
        let farms = store(identity: identity("usr_a"), memory: memory, mirror: mirror,
                          answer: me("usr_a", tenant: ("ferma-1", "Ферма 1")), asked: { asks += 1 })

        XCTAssertEqual(farms.state, .active(Farm(slug: "ferma-2", name: "Ферма 2")), "not open at init")
        XCTAssertEqual(mirror.farm?.slug, "ferma-2", "paths would still be built for another farm")
        await farms.resolve()
        XCTAssertEqual(asks, 0, "a remembered farm waited on /me")
    }

    /// A first sign-in on this phone starts at `/me`'s farm and remembers it.
    func testAFirstSignInStartsAtMesFarm() async {
        let who = identity(nil)
        defaults.set(true, forKey: FarmMemory.seededKey)
        let farms = store(identity: who, answer: me("usr_b", tenant: ("ferma-1", "Ферма 1")))
        XCTAssertEqual(farms.state, .resolving)

        await farms.resolve()
        XCTAssertEqual(farms.state, .active(Farm(slug: "ferma-1", name: "Ферма 1")))
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_b")?.slug, "ferma-1",
                       "the next launch would wait on /me again")
    }

    /// Who it is is only known once `/me` answers — and then a farm this
    /// person chose before on this phone beats their OLDEST membership.
    func testAChoiceMadeOnThisPhoneBeatsTheOldestMembership() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-2", name: "Ферма 2"), for: "usr_a")
        let farms = store(identity: identity(nil), answer: me("usr_a", tenant: ("ferma-1", "Ферма 1")))

        await farms.resolve()
        XCTAssertEqual(farms.activeFarm?.slug, "ferma-2")
    }

    func testNoTenantIsNoFarm() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        let mirror = ActiveFarm()
        let farms = store(identity: identity(nil), mirror: mirror, answer: me("usr_c", tenant: nil))
        await farms.resolve()
        XCTAssertEqual(farms.state, .none)
        XCTAssertNil(mirror.farm)
    }

    /// No answer is not "no farm": offline on a first sign-in, the person may
    /// well have one.
    func testNoAnswerIsFailureNotNoFarm() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        let farms = store(identity: identity(nil), answer: nil)
        await farms.resolve()
        XCTAssertEqual(farms.state, .failed)
    }

    // MARK: - Nobody's screen changes on the update

    /// Whoever is signed in when this build first runs keeps the farm the app
    /// was pinned to — once, and only for them.
    func testThePinnedFarmIsKeptForWhoeverIsSignedInOnce() {
        let farms = store(identity: identity("usr_a"), answer: nil)
        XCTAssertEqual(farms.activeFarm, Farm(slug: Config.legacyTenantSlug, name: nil))

        // A second person on the same phone afterwards is not seeded.
        let later = store(identity: identity("usr_b"), answer: nil)
        XCTAssertEqual(later.state, .resolving, "the pinned farm was seeded twice")
    }

    func testNobodySignedInSeedsNothing() {
        let farms = store(identity: identity(nil), answer: nil)
        XCTAssertEqual(farms.state, .resolving)
        XCTAssertTrue(defaults.bool(forKey: FarmMemory.seededKey), "the seed would run again later")
    }

    func testAChoiceAlreadyMadeIsNotOverwrittenBySeeding() {
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-2", name: nil), for: "usr_a")
        let farms = store(identity: identity("usr_a"), answer: nil)
        XCTAssertEqual(farms.activeFarm?.slug, "ferma-2")
    }

    // MARK: - Switching, naming, signing out

    /// The farm's own shared stores are reset on a CHANGE of farm — not on
    /// the first farm, and not on re-activating the same one.
    func testAChangeOfFarmResetsTheFarmsStores() {
        defaults.set(true, forKey: FarmMemory.seededKey)
        var resets = 0
        let farms = store(identity: identity("usr_a"), answer: nil, changed: { resets += 1 })
        farms.activate(Farm(slug: "ferma-1", name: nil))
        farms.activate(Farm(slug: "ferma-1", name: "Ферма 1"))
        XCTAssertEqual(resets, 0)
        farms.activate(Farm(slug: "ferma-2", name: nil))
        XCTAssertEqual(resets, 1)
    }

    /// The pinned farm is seeded by slug; `/me` can name it — and only it.
    func testMeNamesTheOpenFarmOnly() {
        let farms = store(identity: identity("usr_a"), answer: nil)
        farms.adoptName(from: .init(id: "ten_x", name: "Друга ферма", slug: "druga"))
        XCTAssertNil(farms.activeFarm?.name, "another farm's name was taken")
        farms.adoptName(from: .init(id: "ten_a", name: "Агрент", slug: Config.legacyTenantSlug))
        XCTAssertEqual(farms.activeFarm, Farm(slug: Config.legacyTenantSlug, name: "Агрент"))
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_a")?.name, "Агрент")
    }

    /// Изход closes the farm for whoever signs in next, and keeps the choice
    /// for the person who made it.
    func testSignOutClosesTheFarmAndKeepsTheChoice() {
        let mirror = ActiveFarm()
        let farms = store(identity: identity("usr_a"), mirror: mirror, answer: nil)
        XCTAssertNotNil(mirror.farm, "positive control: a farm was open")
        farms.reset()
        XCTAssertEqual(farms.state, .resolving)
        XCTAssertNil(mirror.farm)
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_a")?.slug, Config.legacyTenantSlug)
    }
}

/// Paths follow the open farm, and a queued record follows the farm it was
/// made on — whichever is open when it is sent.
final class FarmPathTests: XCTestCase {
    private var saved: Farm?

    override func setUp() {
        super.setUp()
        saved = ActiveFarm.shared.farm
    }

    override func tearDown() {
        ActiveFarm.shared.set(saved)
        super.tearDown()
    }

    func testPathsFollowTheOpenFarm() {
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        XCTAssertEqual(Config.tenantSlug, "ferma-1")
        XCTAssertEqual(LocationsAPI.listPath, "/api/t/ferma-1/locations")
        ActiveFarm.shared.set(nil)
        XCTAssertEqual(Config.tenantSlug, Config.legacyTenantSlug, "no farm built /api/t//")
    }

    private func create(farm: String?) -> PendingOperation {
        PendingOperation(id: "op_1", locationID: "loc_1", ownerUserID: "usr_a", tenantSlug: farm,
                         parcelSummary: "x", payload: Data(), createdAt: Date(),
                         attempts: 0, lastAttemptAt: nil, lastError: nil)
    }

    /// A spray queued on one farm goes to that farm after a switch — sent to
    /// the farm open now, its location id would be "not found" and refused.
    func testAQueuedRecordGoesToTheFarmItWasMadeOn() {
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        XCTAssertEqual(OutboxStore.replay(for: create(farm: "ferma-2")),
                       .create(path: "/api/t/ferma-2/locations/loc_1/operations", idempotencyKey: "op_1"))

        let mark = PendingOperation.mark(
            PendingOperation.LineMark(taskID: "tsk_1", lineID: "opl_1", status: "DONE", seenVersion: 3),
            ownerUserID: "usr_a", summary: "x", payload: Data(), reason: nil)
        var stampedMark = mark
        stampedMark.tenantSlug = "ferma-2"
        XCTAssertEqual(OutboxStore.replay(for: stampedMark),
                       .mark(path: "/api/t/ferma-2/field-operations/tsk_1/parcels/opl_1", seenVersion: 3))
    }

    /// A row from before records carried a farm was made on the pinned one.
    func testARowFromBeforeFarmsGoesToThePinnedFarm() throws {
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        let encoded = try JSONEncoder().encode(create(farm: nil))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["tenantSlug"], "positive control: a nil farm is not written")
        object.removeValue(forKey: "tenantSlug")
        let legacy = try JSONDecoder().decode(
            PendingOperation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.tenant, Config.legacyTenantSlug)
        XCTAssertEqual(OutboxStore.replay(for: legacy),
                       .create(path: "/api/t/\(Config.legacyTenantSlug)/locations/loc_1/operations",
                               idempotencyKey: "op_1"))
    }

    /// Queued on the farm open now; a row that already says its farm keeps it.
    func testEnqueueStampsTheOpenFarm() {
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        XCTAssertEqual(OutboxStore.stamped(create(farm: nil)).tenantSlug, "ferma-1")
        XCTAssertEqual(OutboxStore.stamped(create(farm: "ferma-2")).tenantSlug, "ferma-2")
    }
}
