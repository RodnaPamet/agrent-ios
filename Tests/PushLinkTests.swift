import XCTest
@testable import Agrent

/// A tapped notification's way to its screen (#368): the link, the inbox it
/// waits in, the farm it needs, and the route it becomes. Synthetic slugs
/// and ids.
@MainActor
final class PushLinkTests: XCTestCase {
    // MARK: - The link

    /// The one link sent to phones today: a task assigned to the person
    /// (agri-saas `notifications/assignment.ts`).
    func testATaskLinkNamesItsFarmAndTask() {
        XCTAssertEqual(PushLink.parse("/t/ferma-1/farm-tasks/task-42"), .task(farm: "ferma-1", id: "task-42"))
        XCTAssertEqual(PushLink.parse("/t/ferma-1/farm-tasks/task-42?from=push"),
                       .task(farm: "ferma-1", id: "task-42"), "a query is not part of the path")
        XCTAssertEqual(PushLink.parse("/t/ferma-1/farm-tasks/a%2Fb"), .task(farm: "ferma-1", id: "a/b"),
                       "an encoded separator stays inside the id")
    }

    /// Only paths the server sends, and only ones the app can show.
    func testAnythingElseIsNoLink() {
        for link in [nil, "", "t/ferma-1/farm-tasks/1", "//elsewhere/t/ferma-1/farm-tasks/1",
                     "https://app.agrent.bg/t/ferma-1/farm-tasks/1", "/t/ferma-1/farm-tasks/",
                     "/t/ferma-1/farm-tasks/1/evidence", "/t//farm-tasks/1", "/t/ferma-1/locations/1",
                     "/farm-tasks/1"] {
            XCTAssertNil(PushLink.parse(link), String(describing: link))
        }
    }

    // MARK: - The inbox

    func testTheFarmsTabsTakeTheLinkOnce() {
        let inbox = PushInbox()
        inbox.receive(link: "/t/ferma-1/farm-tasks/task-42")
        XCTAssertNil(inbox.take(in: "ferma-2"), "another farm's tabs don't take it")
        XCTAssertEqual(inbox.take(in: "ferma-1"), .task(farm: "ferma-1", id: "task-42"))
        XCTAssertNil(inbox.take(in: "ferma-1"), "taken once")
    }

    /// The latest tap is what the person asked for: one the app can't show
    /// doesn't leave an older link to open in its place.
    func testTheLatestTapWins() {
        let inbox = PushInbox()
        inbox.receive(link: "/t/ferma-1/farm-tasks/1")
        inbox.receive(link: "/t/ferma-1/farm-tasks/2")
        XCTAssertEqual(inbox.current, .task(farm: "ferma-1", id: "2"))
        inbox.receive(link: "/t/ferma-1/locations/9")
        XCTAssertNil(inbox.current)
    }

    /// A link from before a sign-out names the last person's farm.
    func testALinkFromAnotherSessionIsNotOpened() {
        let inbox = PushInbox()
        inbox.receive(link: "/t/ferma-1/farm-tasks/1")
        SessionEpoch.advance()
        XCTAssertNil(inbox.current)
        XCTAssertNil(inbox.take(in: "ferma-1"))
    }

    // MARK: - The farm

    private let farm1 = Farm(slug: "ferma-1", name: "Стопанство 1")
    private let farm2 = Farm(slug: "ferma-2", name: "Стопанство 2")

    func testTheGateOpensTheLinksFarmOnlyFromThePersonsList() {
        let link = PushLink.task(farm: "ferma-2", id: "1")
        XCTAssertEqual(FarmGate.linkStep(link, active: farm2, list: nil), .here)
        XCTAssertEqual(FarmGate.linkStep(link, active: farm1, list: nil), .wait, "the list decides")
        XCTAssertEqual(FarmGate.linkStep(link, active: farm1, list: [farm1, farm2]), .open(farm2))
        XCTAssertEqual(FarmGate.linkStep(link, active: farm1, list: [farm1]), .notYours)
        XCTAssertEqual(FarmGate.linkStep(link, active: nil, list: [farm2]), .open(farm2))
    }

    // MARK: - The screen

    func testATaskLinkOpensTheTaskOnZadachi() {
        let route = AppRoute(.task(farm: "ferma-1", id: "task-42"))
        XCTAssertEqual(route, .taskID("task-42"))
        XCTAssertEqual(route.home, .tasks)
        XCTAssertNotEqual(route, .taskID("task-43"))
    }

    /// The task's own read stands for the row a tap would have started
    /// from: the screen draws its title, kind and status from it.
    func testATaskReadMakesTheRowItsScreenNeeds() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "task-detail-task", withExtension: "json"))
        let item = try await WorkItemAPI.decodeDetail(from: Data(contentsOf: url))
        let row = WorkItemSummary(item: item)
        XCTAssertEqual(row.id, item.id)
        XCTAssertEqual(row.key, item.key)
        XCTAssertEqual(row.title, item.title)
        XCTAssertEqual(row.type, item.type)
        XCTAssertEqual(row.status, item.status)
        XCTAssertEqual(row.severity, item.severity)
        XCTAssertEqual(row.assigneeUserId, item.assigneeUserId)
    }
}
