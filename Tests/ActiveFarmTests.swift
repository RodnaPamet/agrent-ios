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

    /// The farm list, one answer per request (the last one repeats); nil is
    /// a request that fails. `onAsk` runs while a request is on its way —
    /// where a sign-out or a new farm lands in the tests that need one.
    @MainActor
    private final class FarmList {
        private var answers: [[FarmsAPI.Membership]?]
        private(set) var asked = 0
        var onAsk: (() -> Void)?

        init(_ answers: [[FarmsAPI.Membership]?]) { self.answers = answers }

        func load() throws -> [FarmsAPI.Membership] {
            asked += 1
            onAsk?()
            let answer = answers.count > 1 ? answers.removeFirst() : (answers.first ?? nil)
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }
    }

    /// A store whose `/me` is `answer`, counting how often it is asked — and
    /// adopting the answer's id as the real store does, since `/me` is how a
    /// fresh sign-in learns who it is. The farm list fails unless one is
    /// given, and the roles the store announces are collected rather than
    /// handed to the app's `CurrentUserStore`.
    private func store(
        identity: SessionIdentity, memory: FarmMemory? = nil, mirror: ActiveFarm = ActiveFarm(),
        answer: CurrentUser?, asked: (() -> Void)? = nil, changed: (() -> Void)? = nil,
        list: FarmList? = nil, roles: ((String?) -> Void)? = nil
    ) -> FarmStore {
        let list = list ?? FarmList([nil])
        return FarmStore(
            identity: identity,
            memory: memory ?? FarmMemory(defaults: defaults),
            mirror: mirror,
            loadMe: {
                asked?()
                if let answer { identity.adopt(answer.id) }
                return answer
            },
            loadFarms: { try list.load() },
            onFarmChange: { changed?() },
            adoptRole: { roles?($0) })
    }

    private func member(_ slug: String, _ name: String, _ role: String) -> FarmsAPI.Membership {
        FarmsAPI.Membership(slug: slug, name: name, role: role)
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

    /// A first sign-in on this phone starts at `/me`'s farm and remembers it
    /// — with `/me`'s role, which is the role on that same membership.
    func testAFirstSignInStartsAtMesFarm() async {
        let who = identity(nil)
        defaults.set(true, forKey: FarmMemory.seededKey)
        var roles: [String?] = []
        let farms = store(identity: who, answer: me("usr_b", tenant: ("ferma-1", "Ферма 1")),
                          roles: { roles.append($0) })
        XCTAssertEqual(farms.state, .resolving)

        await farms.resolve()
        XCTAssertEqual(farms.state, .active(Farm(slug: "ferma-1", name: "Ферма 1", role: "OWNER")))
        XCTAssertEqual(roles, ["OWNER"], "the first farm opened on no role at all")
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
        XCTAssertEqual(farms.activeFarm, Farm(slug: Config.pinnedFarmSlug, name: nil))

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
        farms.adoptName(from: .init(id: "ten_a", name: "Агрент", slug: Config.pinnedFarmSlug))
        XCTAssertEqual(farms.activeFarm, Farm(slug: Config.pinnedFarmSlug, name: "Агрент"))
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
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_a")?.slug, Config.pinnedFarmSlug)
    }

    // MARK: - The farm list (stage 3)

    /// The list names the farm seeded by slug, says this person's role in it,
    /// and that role is what gates the screens — remembered for a launch with
    /// no signal. The same farm, so nothing is rebuilt.
    func testTheListNamesTheOpenFarmAndSaysTheRoleThere() async {
        var roles: [String?] = []
        var resets = 0
        let list = FarmList([[member(Config.pinnedFarmSlug, "Агрент", "MECHANISATOR"),
                               member("ferma-2", "Ферма 2", "OWNER")]])
        let farms = store(identity: identity("usr_a"), answer: nil, changed: { resets += 1 },
                          list: list, roles: { roles.append($0) })
        XCTAssertEqual(farms.activeFarm, Farm(slug: Config.pinnedFarmSlug, name: nil),
                       "positive control: the seeded farm, unnamed and with no role")

        await farms.refreshFarms()
        let named = Farm(slug: Config.pinnedFarmSlug, name: "Агрент", role: "MECHANISATOR")
        XCTAssertEqual(farms.activeFarm, named)
        XCTAssertEqual(roles.last, "MECHANISATOR", "the screens would gate on the oldest membership's role")
        XCTAssertEqual(resets, 0, "the same farm was treated as a switch")
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_a"), named,
                       "a launch with no signal would forget the role")
        XCTAssertEqual(farms.farms?.map(\.slug), [Config.pinnedFarmSlug, "ferma-2"], "Профил has no list")
        XCTAssertNil(farms.lostAccess)
        XCTAssertFalse(farms.listUnavailable)
    }

    /// A remembered farm the list no longer has is CLOSED — the spec's
    /// "unreachable, not merely unlisted" — for the oldest membership, and
    /// the person is told which.
    func testAFarmNoLongerListedIsClosed() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-2", name: "Ферма 2", role: "OWNER"),
                                                for: "usr_a")
        var resets = 0
        var roles: [String?] = []
        let mirror = ActiveFarm()
        let farms = store(identity: identity("usr_a"), mirror: mirror, answer: nil,
                          changed: { resets += 1 },
                          list: FarmList([[member("ferma-1", "Ферма 1", "EDITOR")]]),
                          roles: { roles.append($0) })
        XCTAssertEqual(farms.activeFarm?.slug, "ferma-2", "positive control: the remembered farm opened")

        await farms.refreshFarms()
        XCTAssertEqual(farms.activeFarm, Farm(slug: "ferma-1", name: "Ферма 1", role: "EDITOR"))
        XCTAssertEqual(mirror.farm?.slug, "ferma-1", "paths would still be built for the farm that is gone")
        XCTAssertEqual(farms.lostAccess?.name, "Ферма 2", "the person would not be told")
        XCTAssertEqual(resets, 1, "the gone farm's badge and pauses would carry over")
        XCTAssertEqual(roles.last, "EDITOR")
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_a")?.slug, "ferma-1",
                       "the next launch would open the gone farm again")

        farms.acknowledgeLostAccess()
        XCTAssertNil(farms.lostAccess)
    }

    /// No farm left is no farm — and nothing remembered, so the next launch
    /// does not open the gone one again.
    func testNoFarmLeftIsNoFarm() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-2", name: "Ферма 2", role: "OWNER"),
                                                for: "usr_a")
        var roles: [String?] = []
        let mirror = ActiveFarm()
        let farms = store(identity: identity("usr_a"), mirror: mirror, answer: nil,
                          list: FarmList([[]]), roles: { roles.append($0) })

        await farms.refreshFarms()
        XCTAssertEqual(farms.state, .none)
        XCTAssertNil(mirror.farm)
        XCTAssertEqual(farms.lostAccess?.slug, "ferma-2")
        XCTAssertNil(FarmMemory(defaults: defaults).farm(for: "usr_a"))
        XCTAssertEqual(roles.last, .some(nil), "the closed farm's role would still gate the screens")
    }

    /// Offline, nothing changes but the note — and the note goes once the
    /// list can be read.
    func testAListThatCannotBeReadChangesNothing() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        let remembered = Farm(slug: "ferma-2", name: "Ферма 2", role: "OWNER")
        FarmMemory(defaults: defaults).remember(remembered, for: "usr_a")
        let list = FarmList([nil, [member("ferma-2", "Ферма 2", "OWNER")]])
        let farms = store(identity: identity("usr_a"), answer: nil, list: list)

        await farms.refreshFarms()
        XCTAssertEqual(farms.activeFarm, remembered, "a failed read closed or changed the farm")
        XCTAssertNil(farms.farms)
        XCTAssertTrue(farms.listUnavailable, "Профил would not say why the list is missing")
        XCTAssertNil(farms.lostAccess)

        await farms.refreshFarms()
        XCTAssertFalse(farms.listUnavailable)
        XCTAssertEqual(farms.farms, [remembered])
    }

    /// A list asked for before a farm was CREATED does not have it, and must
    /// not close it: the answer is set aside and the list asked for again.
    func testAListFromBeforeAFarmWasCreatedDoesNotCloseIt() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-1", name: "Ферма 1", role: "OWNER"),
                                                for: "usr_a")
        let created = Farm(slug: "nova", name: "Нова ферма", role: "OWNER")
        let list = FarmList([[member("ferma-1", "Ферма 1", "OWNER")],
                             [member("ferma-1", "Ферма 1", "OWNER"), member("nova", "Нова ферма", "OWNER")]])
        var farms: FarmStore?
        // The wizard finishes while the first list is on its way.
        list.onAsk = { [unowned list] in if list.asked == 1 { farms?.open(created) } }
        farms = store(identity: identity("usr_a"), answer: nil, list: list)

        await farms?.refreshFarms()
        XCTAssertEqual(list.asked, 2, "the answer from before the farm existed was acted on")
        XCTAssertEqual(farms?.activeFarm, created, "a list from before the farm existed closed it")
        XCTAssertNil(farms?.lostAccess)
        XCTAssertEqual(farms?.farms?.map(\.slug), ["ferma-1", "nova"])
    }

    /// A's list answering after Изход is nobody's: it opens nothing, lists
    /// nothing, and rewrites nothing A chose.
    func testAListThatAnswersAfterIzhodIsDropped() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-2", name: "Ферма 2"), for: "usr_a")
        let list = FarmList([[member("ferma-1", "Ферма 1", "OWNER")]])
        var farms: FarmStore?
        list.onAsk = {
            SessionEpoch.advance()
            farms?.reset()
        }
        farms = store(identity: identity("usr_a"), answer: nil, list: list)
        XCTAssertEqual(farms?.activeFarm?.slug, "ferma-2", "positive control")

        await farms?.refreshFarms()
        XCTAssertEqual(farms?.state, .resolving, "A's list opened a farm for whoever signs in next")
        XCTAssertNil(farms?.farms, "A's farms would be listed in the next person's Профил")
        XCTAssertNil(farms?.lostAccess)
        XCTAssertEqual(FarmMemory(defaults: defaults).farm(for: "usr_a")?.slug, "ferma-2",
                       "A's choice was rewritten after Изход")
    }

    /// A farm the list closed is not reopened from `/me`, whose tenant still
    /// names it until it is re-read. Before the gate's modifiers moved off a
    /// `Group`, every change of state ran `resolve()` again, and this was a
    /// loop: reopened from `/me`, closed by the list, reopened…
    func testAClosedFarmIsNotReopenedFromMe() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        FarmMemory(defaults: defaults).remember(Farm(slug: "ferma-2", name: "Ферма 2", role: "OWNER"),
                                                for: "usr_a")
        var asks = 0
        let farms = store(identity: identity("usr_a"), answer: me("usr_a", tenant: ("ferma-2", "Ферма 2")),
                          asked: { asks += 1 }, list: FarmList([[]]))
        await farms.refreshFarms()
        XCTAssertEqual(farms.state, .none, "positive control: the list closed it")

        await farms.resolve()
        XCTAssertEqual(farms.state, .none, "/me reopened the farm the list had just closed")
        XCTAssertEqual(asks, 0, "/me was asked although the list had answered")
        XCTAssertNil(FarmMemory(defaults: defaults).farm(for: "usr_a"), "the closed farm was remembered again")
    }

    /// Invited on the web while this phone said «Нямате стопанство»: the next
    /// list lets them in, rather than leaving the wizard to make a second farm.
    func testAFarmGivenWhileThereWasNoneOpens() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        let farms = store(identity: identity(nil), answer: me("usr_c", tenant: nil),
                          list: FarmList([[member("ferma-1", "Ферма 1", "EDITOR")]]))
        await farms.resolve()
        XCTAssertEqual(farms.state, .none, "positive control: no farm yet")

        await farms.refreshFarms()
        XCTAssertEqual(farms.activeFarm, Farm(slug: "ferma-1", name: "Ферма 1", role: "EDITOR"))
        XCTAssertNil(farms.lostAccess, "nothing was lost")
    }

    /// A first sign-in that could not reach `/me` gets its farm from the list
    /// when the list can be read.
    func testAFirstSignInThatFailedOpensFromTheList() async {
        defaults.set(true, forKey: FarmMemory.seededKey)
        let farms = store(identity: identity(nil), answer: nil,
                          list: FarmList([[member("ferma-1", "Ферма 1", "OWNER")]]))
        await farms.resolve()
        XCTAssertEqual(farms.state, .failed, "positive control")

        await farms.refreshFarms()
        XCTAssertEqual(farms.activeFarm?.slug, "ferma-1")
    }

    /// Изход forgets the list and the role with the farm.
    func testSignOutForgetsTheListAndTheRole() async {
        var roles: [String?] = []
        let farms = store(identity: identity("usr_a"), answer: nil,
                          list: FarmList([[member(Config.pinnedFarmSlug, "Агрент", "OWNER")]]),
                          roles: { roles.append($0) })
        await farms.refreshFarms()
        XCTAssertNotNil(farms.farms, "positive control")
        farms.reset()
        XCTAssertNil(farms.farms)
        XCTAssertEqual(roles.last, .some(nil))
    }

    // MARK: - Words

    func testTheLostFarmIsNamedWithTheOneOpenNow() {
        XCTAssertEqual(
            FarmGate.lostAccessMessage(Farm(slug: "f2", name: "Ферма 2"), now: Farm(slug: "f1", name: "Ферма 1")),
            "«Ферма 2» вече не е сред стопанствата Ви. Отворено е стопанство «Ферма 1».")
        XCTAssertEqual(
            FarmGate.lostAccessMessage(Farm(slug: Config.pinnedFarmSlug, name: nil), now: nil),
            "Стопанството, което беше отворено, вече не е сред стопанствата Ви.")
    }

    func testRolesAreSaidInBulgarianOrNotAtAll() {
        XCTAssertEqual(ProfileView.roleLabel("OWNER"), "Собственик")
        XCTAssertEqual(ProfileView.roleLabel("MECHANISATOR"), "Механизатор")
        XCTAssertNil(ProfileView.roleLabel("SUPERVISOR"), "an English token on a Bulgarian page")
        XCTAssertNil(ProfileView.roleLabel(nil))
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
        XCTAssertEqual(FarmPath.openSlug, "ferma-1")
        XCTAssertEqual(LocationsAPI.listPath, "/api/t/ferma-1/locations")
        ActiveFarm.shared.set(Farm(slug: "ferma-2", name: nil))
        XCTAssertEqual(LocationsAPI.listPath, "/api/t/ferma-2/locations", "a path kept the farm before")
    }

    /// With no farm open a farm path names NO farm — never the pinned one —
    /// and is refused before a request is built (#192, P4.3).
    func testWithNoFarmOpenAPathGoesNowhere() {
        ActiveFarm.shared.set(nil)
        let path = LocationsAPI.listPath
        XCTAssertEqual(path, "/api/t//locations", "a farm the person did not choose was put in the path")
        XCTAssertTrue(FarmPath.isUnscoped(path))
        XCTAssertThrowsError(try APIClient.url(for: path)) { error in
            guard case APIClient.APIError.noFarmOpen = error else { return XCTFail("refused as \(error)") }
        }
        XCTAssertEqual(UserMessage.text(for: APIClient.APIError.noFarmOpen), "Няма отворено стопанство.")

        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        XCTAssertFalse(FarmPath.isUnscoped(LocationsAPI.listPath))
        XCTAssertNoThrow(try APIClient.url(for: LocationsAPI.listPath), "positive control: a farm is open")
    }

    /// No farm, no cache key: an entry has to belong to a farm, and keying it
    /// under the pinned one is the guess #192 stopped making.
    func testWithNoFarmOpenNothingIsCached() {
        let identity = SessionIdentity(load: { "usr_a" }, save: { _ in })
        ActiveFarm.shared.set(nil)
        XCTAssertNil(CacheScope.current(identity: identity))
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        XCTAssertEqual(CacheScope.current(identity: identity), CacheScope(userID: "usr_a", tenant: "ferma-1"))
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
        XCTAssertEqual(legacy.tenant, Config.pinnedFarmSlug)
        XCTAssertEqual(OutboxStore.replay(for: legacy),
                       .create(path: "/api/t/\(Config.pinnedFarmSlug)/locations/loc_1/operations",
                               idempotencyKey: "op_1"))
    }

    /// Queued on the farm open now; a row that already says its farm keeps it.
    func testEnqueueStampsTheOpenFarm() {
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
        XCTAssertEqual(OutboxStore.stamped(create(farm: nil)).tenantSlug, "ferma-1")
        XCTAssertEqual(OutboxStore.stamped(create(farm: "ferma-2")).tenantSlug, "ferma-2")
        // No farm open: nothing to stamp — and not the pinned farm either.
        ActiveFarm.shared.set(nil)
        XCTAssertNil(OutboxStore.stamped(create(farm: nil)).tenantSlug, "a row was given a farm nobody had open")
    }
}

/// The open farm's role is the role every screen gates on: `CurrentUserStore`
/// hands it out in `user`, and tells the bar (agrent-ios#179, stage 3).
@MainActor
final class FarmRoleTests: XCTestCase {
    private var operatorFlags: [Bool] = []
    private var tabs: [CurrentUser] = []

    private func store(answer: CurrentUser?) -> CurrentUserStore {
        CurrentUserStore(
            fetchCacheFirst: { .init(user: answer) },
            fetchFresh: { answer.map { .loaded($0, .fresh) } ?? .failed("offline") },
            identity: SessionIdentity(load: { nil }, save: { _ in }),
            flags: FeatureFlags(),
            adoptTabs: { [unowned self] in self.tabs.append($0) },
            adoptOperator: { [unowned self] in self.operatorFlags.append($0) })
    }

    private let oldest = CurrentUser(id: "usr_a", name: "А", email: "a@example.invalid", role: "OWNER",
                                     bottomTabOrder: ["/tasks"])

    func testTheOpenFarmsRoleIsTheUsersRole() async {
        let store = store(answer: oldest)
        let first = await store.load()
        XCTAssertEqual(first?.role, "OWNER", "positive control: /me's role until a farm says")

        store.adoptRoleHere("MECHANISATOR")
        XCTAssertEqual(store.user?.role, "MECHANISATOR")
        XCTAssertEqual(store.user?.isOperator, true)
        XCTAssertEqual(store.user?.mayWrite, false)
        XCTAssertEqual(operatorFlags, [true], "the bar kept the oldest membership's tabs")
        let later = await store.load()
        XCTAssertEqual(later?.role, "MECHANISATOR", "a screen loading /me got the oldest membership's role")
        let settled = await store.settled()
        XCTAssertEqual(settled?.role, "MECHANISATOR")

        store.adoptRoleHere(nil)
        XCTAssertEqual(store.user?.role, "OWNER", "no farm role: /me's stands")
        XCTAssertEqual(operatorFlags, [true, false])
    }

    /// Known before `/me` answers — a remembered farm on an offline launch —
    /// it shapes the bar at once, and the bar `/me` then builds.
    func testARoleKnownBeforeMeAnswersShapesTheBar() async {
        let store = store(answer: oldest)
        store.adoptRoleHere("MECHANISATOR")
        XCTAssertEqual(operatorFlags, [true], "an operator's offline launch drew tabs that 403")

        _ = await store.load()
        XCTAssertEqual(tabs.last?.isOperator, true, "/me's answer put the oldest membership's tabs back")
        XCTAssertEqual(tabs.last?.bottomTabOrder, ["/tasks"], "the bar order is the person's, not the farm's")
    }

    /// A foreground refresh hands out the farm's role too.
    func testARefreshKeepsTheFarmsRole() async {
        let store = store(answer: oldest)
        store.adoptRoleHere("READER")
        let fresh = await store.refresh()
        XCTAssertEqual(fresh?.role, "READER")
        XCTAssertEqual(tabs.last?.role, "READER")
    }

    func testIzhodForgetsTheRole() async {
        let store = store(answer: oldest)
        _ = await store.load()
        store.adoptRoleHere("READER")
        store.clear()
        store.adoptForTesting(oldest)
        XCTAssertEqual(store.user?.role, "OWNER", "the departing farm's role reached the next session")
    }

    /// Only the role moves: everything else is the person's own.
    func testInFarmReplacesTheRoleAlone() {
        let there = oldest.inFarm(role: "READER")
        XCTAssertEqual(there.role, "READER")
        XCTAssertEqual(there.id, oldest.id)
        XCTAssertEqual(there.bottomTabOrder, oldest.bottomTabOrder)
        XCTAssertEqual(oldest.inFarm(role: nil), oldest)
    }
}
