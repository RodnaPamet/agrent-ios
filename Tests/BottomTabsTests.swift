import XCTest
@testable import Agrent

@MainActor
final class BottomTabsTests: XCTestCase {

    private func store(_ order: [String]?) -> BottomTabsStore {
        let store = BottomTabsStore.shared
        store.adopt(order)
        return store
    }

    override func tearDown() {
        BottomTabsStore.shared.adopt(nil)
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
    func testUnknownSurfacesFromTheWebAreIgnored() {
        let tabs = store(["/dashboard", "/journal", "/rent", "/exchange"]).bottomTabs
        XCTAssertEqual(tabs, [.journal, .exchange])
    }

    /// …but an order containing ONLY surfaces this app lacks would leave
    /// an empty tab bar, which is not a preference anyone expressed.
    func testAnOrderThisAppCannotDrawFallsBack() {
        XCTAssertEqual(store(["/dashboard", "/rent", "/schemes"]).bottomTabs,
                       AppSurface.fallback)
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
        for order in [nil, ["/trends"], ["/journal", "/news"],
                      ["/dashboard"], []] as [[String]?] {
            let s = store(order)
            let reachable = Set(s.bottomTabs.map(\.id)).union(s.overflow.map(\.id))
            XCTAssertEqual(reachable, Set(AppSurface.allCases.map(\.id)),
                           "order \(String(describing: order)) stranded a surface")
        }
    }

    func testTheOverflowIsExactlyWhatIsNotInTheBar() {
        let s = store(["/journal", "/news"])
        XCTAssertEqual(Set(s.overflow.map(\.id)),
                       Set([AppSurface.calculator, .exchange, .locations, .tasks, .trends]
                            .map(\.id)))
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

    /// Read from the envelope root too. Guessing one location and being
    /// wrong would decode nil forever — a save that silently never
    /// persists — rather than fail loudly.
    func testItIsAlsoReadFromTheEnvelopeRoot() async throws {
        let user = try await me("""
        {"user":{"id":"u","role":"OWNER"},"bottomTabOrder":["/news"]}
        """)
        XCTAssertEqual(user.bottomTabOrder, ["/news"])
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
