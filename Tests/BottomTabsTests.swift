import XCTest
@testable import Agrent

@MainActor
final class BottomTabsTests: XCTestCase {

    private func store(_ order: [String]?, isOperator: Bool = false) -> BottomTabsStore {
        let store = BottomTabsStore.shared
        store.adopt(order, isOperator: isOperator)
        return store
    }

    override func tearDown() {
        BottomTabsStore.shared.adopt(nil, isOperator: false)
        super.tearDown()
    }

    /// The raw values ARE the web's route suffixes, because the stored
    /// array is shared. Inventing `"journal"` for `"/journal"` would make
    /// the sync per-client while looking like it worked.
    func testIDsAreTheWebsRouteSuffixes() {
        XCTAssertEqual(AppSurface.journal.rawValue, "/journal")
        XCTAssertEqual(AppSurface.tasks.rawValue, "/farm-tasks")
        XCTAssertEqual(AppSurface.exchange.rawValue, "/exchange")
        XCTAssertEqual(AppSurface.locations.rawValue, "/locations")
        XCTAssertEqual(AppSurface.trends.rawValue, "/trends")
        XCTAssertEqual(AppSurface.news.rawValue, "/news")
    }

    /// Two of the web's suffixes are two segments deep, so nothing may
    /// assume one path component.
    func testATwoSegmentSuffixIsIntact() {
        XCTAssertEqual(AppSurface.calculator.rawValue, "/grain/calculator")
    }

    /// nil is "never chosen" and draws today's bar — NOT the web's
    /// default, which starts with a dashboard this app does not have.
    func testNeverChosenDrawsTheExistingBar() {
        XCTAssertEqual(store(nil).bottomTabs, AppSurface.fallback)
        XCTAssertEqual(AppSurface.fallback.count, 5)
    }

    func testASavedOrderIsHonouredInOrder() {
        let tabs = store(["/trends", "/journal", "/news"]).bottomTabs
        XCTAssertEqual(tabs, [.trends, .journal, .news])
    }

    /// An order saved on the web will contain surfaces this app does not
    /// have. They drop out; they do not fail the load.
    ///
    /// `/dashboard` USED TO BE THE EXAMPLE HERE and is now drawable — «Табло»
    /// shipped. Which is the good failure: this test went red the moment the
    /// app grew the surface, rather than quietly asserting a capability gap
    /// that had closed. The web still offers twenty-two surfaces to this app's
    /// nine, so there is no shortage of genuinely undrawable suffixes.
    func testUnknownSurfacesFromTheWebAreIgnored() {
        let tabs = store(["/inventory", "/journal", "/rent", "/exchange"]).bottomTabs
        XCTAssertEqual(tabs, [.journal, .exchange])
    }

    /// …but an order containing ONLY surfaces this app lacks would leave
    /// an empty tab bar, which is not a preference anyone expressed.
    func testAnOrderThisAppCannotDrawFallsBack() {
        XCTAssertEqual(store(["/inventory", "/rent", "/schemes"]).bottomTabs,
                       AppSurface.fallback)
    }

    /// AND `/dashboard` IS NO LONGER ONE OF THEM.
    ///
    /// It is the first entry in the web's default order, so every order ever
    /// saved from a laptop carries it. Before «Табло» those orders silently
    /// dropped their first entry; now they resolve. Pinned because it is the
    /// visible consequence of adding a surface, and because the previous
    /// version of these tests treated it as permanently undrawable.
    func testTheWebsDashboardNowResolves() {
        XCTAssertEqual(store(["/dashboard", "/journal"]).bottomTabs,
                       [.dashboard, .journal])
        XCTAssertEqual(AppSurface(rawValue: "/dashboard"), .dashboard)
    }

    /// iOS collapses a sixth tab into "More". The cap is enforced on read
    /// as well as on save, because the value can arrive from another
    /// client that had a different idea of the limit.
    func testMoreThanFiveIsTruncatedOnRead() {
        let tabs = store(["/journal", "/exchange", "/locations",
                          "/farm-tasks", "/trends", "/news"]).bottomTabs
        XCTAssertEqual(tabs.count, AppSurface.capacity)
        XCTAssertFalse(tabs.contains(.news))
    }

    /// THE ONE THAT MAKES THE FEATURE SAFE.
    ///
    /// Anything off the bar is in the menu. Without this, removing
    /// Дневник makes the diary unreachable and the customiser becomes a
    /// way to lose a feature.
    func testEverySurfaceIsReachable() {
        for isOperator in [false, true] {
            for order in [nil, ["/trends"], ["/journal", "/news"],
                          ["/dashboard"], ["/inventory"], []] as [[String]?] {
                let s = store(order, isOperator: isOperator)
                let reachable = Set(s.bottomTabs.map(\.id)).union(s.overflow.map(\.id))
                XCTAssertEqual(reachable, Set(s.permitted.map(\.id)),
                               "order \(String(describing: order)) operator=\(isOperator) "
                               + "stranded a surface")
            }
        }
    }

    func testTheOverflowIsExactlyWhatIsNotInTheBar() {
        let s = store(["/journal", "/news"])
        XCTAssertEqual(Set(s.overflow.map(\.id)),
                       Set([AppSurface.calculator, .exchange, .locations, .tasks,
                            .trends, .farmRisk, .dashboard].map(\.id)))
    }

    /// An empty array is a deliberate clear, and distinct from nil in the
    /// column. This client cannot honour an empty tab bar, so it draws
    /// the default — but the DISTINCTION must survive the round trip, and
    /// it is the server that keeps it.
    func testEmptyIsNotTheSameValueAsNever() {
        let cleared = store([])
        XCTAssertEqual(cleared.bottomTabs, AppSurface.fallback)
        XCTAssertNotNil(cleared.storedForTesting, "[] must not be stored as nil")
        XCTAssertEqual(cleared.storedForTesting?.isEmpty, true)

        let never = store(nil)
        XCTAssertNil(never.storedForTesting)
    }
}

@MainActor
final class CurrentUserTabOrderTests: XCTestCase {

    private func me(_ body: String) async throws -> CurrentUser {
        try await APIClient.shared.decode(Data(body.utf8), as: CurrentUser.self)
    }

    /// Exactly what production returned when this was written — the field
    /// had not deployed. Absent must behave as "never chosen".
    func testTheFieldBeingAbsentIsNotAFailure() async throws {
        let user = try await me("""
        {"user":{"id":"u","email":"e","name":"n","role":"OWNER"},
         "tenant":{"id":"t","name":"Agrent","slug":"agrent"}}
        """)
        XCTAssertNil(user.bottomTabOrder)
    }

    func testItIsReadFromInsideTheUserObject() async throws {
        let user = try await me("""
        {"user":{"id":"u","role":"OWNER","bottomTabOrder":["/trends","/journal"]}}
        """)
        XCTAssertEqual(user.bottomTabOrder, ["/trends", "/journal"])
    }

    /// Confirmed nested, so a value at the envelope root is NOT read —
    /// asserted rather than left ambiguous, because the earlier version
    /// accepted both and this is the behaviour that changed.
    func testTheEnvelopeRootIsNotReadAnyMore() async throws {
        let user = try await me("""
        {"user":{"id":"u","role":"OWNER"},"bottomTabOrder":["/news"]}
        """)
        XCTAssertNil(user.bottomTabOrder)
    }

    func testAnExplicitNullIsNil() async throws {
        let user = try await me("""
        {"user":{"id":"u","role":"OWNER","bottomTabOrder":null}}
        """)
        XCTAssertNil(user.bottomTabOrder)
    }

    func testAnExplicitEmptyArraySurvives() async throws {
        let user = try await me("""
        {"user":{"id":"u","role":"OWNER","bottomTabOrder":[]}}
        """)
        XCTAssertEqual(user.bottomTabOrder, [])
    }
}


/// A MECHANISATOR's bar, against the server's own middleware allowlist:
/// anything under `/api/t/{slug}/` outside
/// `farm-tasks|field-operations|tasks|locations|agro` is a 403
/// `operator_scope`.
@MainActor
final class OperatorTabsTests: XCTestCase {

    override func tearDown() {
        BottomTabsStore.shared.adopt(nil, isOperator: false)
        super.tearDown()
    }

    private func store(_ order: [String]?, isOperator: Bool) -> BottomTabsStore {
        let store = BottomTabsStore.shared
        store.adopt(order, isOperator: isOperator)
        return store
    }

    /// Which surfaces clear the server's operator allowlist
    /// (`farm-tasks|field-operations|tasks|locations|agro`).
    ///
    /// `farmRisk` joins them because its READINGS come from `/agro` and
    /// `/locations`, both allowed — a MECHANISATOR sees every parcel's
    /// vegetation and moisture. Only `/insurance` is outside, so the ask
    /// control is hidden for them and the screen is not. Knowing a field
    /// is stressed is field work; contacting an insurer is not.
    ///
    /// Written out literally on purpose: this test failed when Farm Risk
    /// was added, which is exactly what it is for — a new screen cannot
    /// reach the bar without somebody deciding whether an operator may
    /// hold it.
    func testTheOperatorAllowlistIsDecidedPerSurface() {
        let allowed = AppSurface.allCases.filter(\.isOperatorAllowed)
        XCTAssertEqual(Set(allowed), Set([.locations, .tasks, .farmRisk]))
        for blocked in [AppSurface.journal, .calculator, .exchange, .trends, .news] {
            XCTAssertFalse(blocked.isOperatorAllowed, blocked.rawValue)
        }
    }

    /// A tab whose screen 403s is not a tab, it is an error the person
    /// would read as the app being broken.
    func testAnOperatorNeverGetsAForbiddenTab() {
        let s = store(["/journal", "/exchange", "/grain/calculator",
                       "/locations", "/trends"], isOperator: true)
        XCTAssertEqual(s.bottomTabs, [.locations])
        XCTAssertFalse(s.overflow.contains(.journal))
        XCTAssertFalse(s.overflow.contains(.exchange))
    }

    /// Filtering must not leave an empty bar — the default is filtered too.
    func testAnOperatorWithNoPermittedChoiceGetsTheFilteredDefault() {
        let s = store(["/journal", "/exchange"], isOperator: true)
        XCTAssertEqual(s.bottomTabs, [.locations, .tasks])
        XCTAssertFalse(s.bottomTabs.isEmpty)
    }

    func testAnOperatorWhoNeverChoseGetsTheFilteredDefault() {
        XCTAssertEqual(store(nil, isOperator: true).bottomTabs, [.locations, .tasks])
    }

    /// THE ORDERING HAZARD. A role can change after a bar was saved, so
    /// the filter runs on read. The same stored array must produce
    /// different bars for the two roles with nothing migrated.
    func testTheSameSavedOrderResolvesDifferentlyPerRole() {
        let order = ["/journal", "/locations", "/exchange", "/farm-tasks"]
        XCTAssertEqual(store(order, isOperator: false).bottomTabs,
                       [.journal, .locations, .exchange, .tasks])
        XCTAssertEqual(store(order, isOperator: true).bottomTabs,
                       [.locations, .tasks])
    }

    /// An owner loses nothing. A filter that fired for everyone would be
    /// the more damaging bug and would pass every test above.
    func testAnOwnerKeepsEverything() {
        let s = store(nil, isOperator: false)
        XCTAssertEqual(s.permitted.count, AppSurface.allCases.count)
        XCTAssertEqual(s.bottomTabs, AppSurface.fallback)
    }
}

@MainActor
final class OperatorRoleTests: XCTestCase {

    private func me(_ role: String?) -> CurrentUser {
        CurrentUser(id: "u", name: nil, email: nil, role: role)
    }

    func testOnlyMechanisatorIsAnOperator() {
        XCTAssertTrue(me("MECHANISATOR").isOperator)
        XCTAssertTrue(me("mechanisator").isOperator)
    }

    /// READER and AUDITOR are refused WRITES, and whether the same path
    /// lockdown applies to them was never stated. Extending an unverified
    /// rule takes screens away from people who could use them.
    func testRolesRefusedWritesAreNotAssumedToBeOperators() {
        XCTAssertFalse(me("READER").isOperator)
        XCTAssertFalse(me("AUDITOR").isOperator)
        XCTAssertFalse(me("OWNER").isOperator)
        XCTAssertFalse(me(nil).isOperator)
        // …while still being refused the write, which is a separate gate.
        XCTAssertFalse(me("READER").mayCreateOperations)
    }
}

/// The save refusal is keyed on `error.code`, never on the English.
final class TabOrderRefusalTests: XCTestCase {

    /// Exactly the envelope the server sends, from `toApiErrorResponse`.
    func testTheRefusalIsTranslatedFromItsCode() {
        let text = UserMessage.httpText(
            status: 400,
            code: "INVALID_TAB_ORDER",
            message: "order must be null, or an array of up to 12 unique non-empty ids.")
        XCTAssertEqual(text, "Подредбата на разделите не беше приета.")
    }

    /// The English must not leak even though it IS a real sentence and
    /// would therefore pass `isHumanSentence`. The code has to win.
    func testTheEnglishMessageIsNotShown() {
        let english = "order must be null, or an array of up to 12 unique non-empty ids."
        XCTAssertTrue(UserMessage.isHumanSentence(english),
                      "precondition: this would otherwise be rendered")
        XCTAssertFalse(
            UserMessage.httpText(status: 400, code: "INVALID_TAB_ORDER", message: english)
                .contains("order must be"))
    }

    /// The server's cap is 12 and this app's is 5. Quoting the server's
    /// number would state a rule the farmer is not subject to — they
    /// cannot build a twelve-item bar, because the editor stops at five.
    func testTheServersCapIsNotQuoted() {
        let text = UserMessage.httpText(
            status: 400, code: "INVALID_TAB_ORDER",
            message: "order must be null, or an array of up to 12 unique non-empty ids.")
        XCTAssertFalse(text.contains("12"))
        XCTAssertLessThan(AppSurface.capacity, 12)
    }

    /// An unrecognised code still falls back to the server's sentence —
    /// keying on codes must not make unknown refusals silent. Most of the
    /// API is still uncoded, so this is the common path, not the rare one.
    func testAnUnknownCodeStillFallsBackToTheMessage() {
        XCTAssertEqual(
            UserMessage.httpText(status: 400, code: "SOME_FUTURE_CODE",
                                 message: "Something specific went wrong."),
            "Something specific went wrong.")
    }
}
