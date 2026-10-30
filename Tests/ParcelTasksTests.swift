import XCTest
@testable import Agrent

/// A parcel's tasks from Блокове (#462): the route, the «Текущи» / «Архив»
/// split, and what the card says.
final class ParcelTasksTests: XCTestCase {

    /// Rows as the server sends them, through the list's own decoder (and
    /// its dates): `(id, status, title)`, every one opened on 3 October.
    private func tasks(_ rows: [(String, String, String)], truncated: Bool = false) async throws -> ParcelTasks {
        let json = rows.map { id, status, title in
            #"{"id":"\#(id)","key":null,"title":"\#(title)","type":"TASK","status":"\#(status)","createdAt":"2026-10-03T06:30:00.000Z"}"#
        }
        let body = #"{"rows":[\#(json.joined(separator: ","))],"truncated":\#(truncated)}"#
        return ParcelTasks(try await WorkItemAPI.decodeList(from: Data(body.utf8)))
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!

    // MARK: - The route

    /// The parcel's id in the PATH, escaped, and no query: CFNetwork logs
    /// full URLs.
    func testTheParcelIsAPathSegment() {
        let path = WorkItemAPI.parcelTasksPath("par 1")
        XCTAssertTrue(path.hasSuffix("/agro/parcels/par%201/tasks"), path)
        XCTAssertTrue(path.hasPrefix(FarmPath.root), path)
        XCTAssertFalse(path.contains("?"), path)
    }

    /// The agreed answer, the list's envelope, decodes with the list's
    /// decoder, and an unknown status is still a row.
    func testTheAgreedShapeDecodes() async throws {
        let body = #"""
        {"rows":[
          {"id":"a","key":"FT-1","title":"Първа","type":"FIELD_OPERATION","status":"IN_PROGRESS","severity":"MEDIUM",
           "priority":null,"dueAt":null,"createdAt":"2026-10-03T06:30:00.000Z","updatedAt":"2026-10-05T07:55:00.000Z",
           "assigneeUserId":null,"assignee":null,"mayDelete":false},
          {"id":"b","key":null,"title":"Втора","type":"TASK","status":"SOMETHING_NEW","severity":null,
           "priority":null,"dueAt":null,"createdAt":"2026-09-22T06:10:00.000Z","updatedAt":"2026-09-22T06:10:00.000Z",
           "assigneeUserId":null,"assignee":null}
        ],"truncated":true}
        """#
        let page = try await WorkItemAPI.decodeList(from: Data(body.utf8))
        XCTAssertEqual(page.items.map(\.id), ["a", "b"])
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.items.first?.mayDelete, false)
        XCTAssertEqual(page.items.last?.status, .unknown)
    }

    // MARK: - The split

    /// Finished or called off is the archive; everything else, a status
    /// this app does not know included, is current. Server order kept.
    func testTheSplitIsByStatus() async throws {
        let split = try await tasks([
            ("open", "OPEN", "А"), ("done", "RESOLVED", "Б"), ("triaged", "TRIAGED", "В"),
            ("closed", "CLOSED", "Г"), ("blocked", "BLOCKED", "Д"), ("canceled", "CANCELED", "Е"),
            ("review", "PENDING_REVIEW", "Ж"), ("doing", "IN_PROGRESS", "З"), ("new", "SOMETHING_NEW", "И"),
        ])
        XCTAssertEqual(split.current.map(\.id), ["open", "triaged", "blocked", "review", "doing", "new"])
        XCTAssertEqual(split.archived.map(\.id), ["done", "closed", "canceled"])
        XCTAssertEqual(split.rows(.current), split.current)
        XCTAssertEqual(split.rows(.archived), split.archived)
        XCTAssertFalse(split.isEmpty)
        let none = try await tasks([])
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - The card

    /// The newest current task, its status and when it was opened, under how
    /// many there are.
    func testTheCardShowsTheNewestCurrentTask() async throws {
        let card = ParcelTasksCard(try await tasks([
            ("a", "RESOLVED", "Стара"), ("b", "IN_PROGRESS", "Пръскане"), ("c", "OPEN", "Оглед"),
        ]), now: now)
        XCTAssertEqual(card.count, "2 текущи")
        XCTAssertEqual(card.line.headline, "Пръскане")
        XCTAssertEqual(card.line.details.first, WorkItemStatus.inProgress.label)
        XCTAssertEqual(card.line.details.last, "Отворена на \(BgDate.rowDay(ISO8601DateFormatter().date(from: "2026-10-03T06:30:00Z")!, now: now))")
        XCTAssertTrue(card.isTappable)
        XCTAssertTrue(card.spoken.hasPrefix("Задачи, 2 текущи, Пръскане"), card.spoken)
        XCTAssertFalse(card.spoken.contains("·"), "spoken from the values, not the rendered text")
    }

    func testOneCurrentTaskIsSingular() async throws {
        let one = try await tasks([("a", "OPEN", "А")])
        XCTAssertEqual(ParcelTasksCard(one, now: now).count, "1 текуща")
    }

    /// Only archived work: said in words, no count, and still opens the
    /// list, where «Архив» has it.
    func testOnlyArchivedTasksStillOpenTheList() async throws {
        let card = ParcelTasksCard(try await tasks([("a", "CLOSED", "А"), ("b", "CANCELED", "Б")]), now: now)
        XCTAssertNil(card.count)
        XCTAssertNil(card.line.headline)
        XCTAssertEqual(card.line.details, ["Няма текущи задачи", "2 задачи в архива"])
        XCTAssertTrue(card.isTappable)
    }

    /// Nothing at all: one calm line and nothing to push to.
    func testNoTasksIsNotTappable() async throws {
        let card = ParcelTasksCard(try await tasks([]), now: now)
        XCTAssertNil(card.count)
        XCTAssertEqual(card.line.details, ["Няма задачи"])
        XCTAssertFalse(card.isTappable)
        XCTAssertEqual(card.spoken, "Задачи, Няма задачи.")
    }

    /// A capped list is not counted: the number would be the cap's.
    func testACappedListIsNotCounted() async throws {
        let current = ParcelTasksCard(try await tasks([("a", "OPEN", "Оглед")], truncated: true), now: now)
        XCTAssertNil(current.count)
        XCTAssertEqual(current.line.headline, "Оглед", "positive control: the row is still shown")
        let archived = ParcelTasksCard(try await tasks([("a", "CLOSED", "А")], truncated: true), now: now)
        XCTAssertEqual(archived.line.details, ["Няма текущи задачи", "Има задачи в архива"])
    }

    // MARK: - «Изтрий»

    /// Both lists delete through the one `taskRemoval`, and a parcel's
    /// list offers the swipe as Задачи does (owner, 2026-10-30).
    func testBothListsShareTheDelete() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let parcel = try String(contentsOf: root.appendingPathComponent("Agrent/Locations/ParcelTasksView.swift"), encoding: .utf8)
        let tasks = try String(contentsOf: root.appendingPathComponent("Agrent/Tasks/TasksListView.swift"), encoding: .utf8)
        for (name, source) in [("ParcelTasksView", parcel), ("TasksListView", tasks)] {
            XCTAssertTrue(source.contains(".taskRemoval(removal, asking: $confirmingRemoval, confirming: $confirming)"), name)
            XCTAssertTrue(source.contains(".taskRemovalSwipe(item, me: people.user)"), name)
            XCTAssertTrue(source.contains("removal.visible("), name)
            XCTAssertFalse(source.contains(".swipeActions("), "\(name) builds its own swipe")
        }
    }

    /// A row swiped away leaves the list it was in, whichever tab.
    @MainActor
    func testASwipedRowLeavesTheList() async throws {
        let body = #"{"rows":[{"id":"a","title":"А","type":"TASK","status":"OPEN"},{"id":"b","title":"Б","type":"TASK","status":"OPEN"},{"id":"c","title":"В","type":"TASK","status":"CLOSED"}],"truncated":false}"#
        let split = ParcelTasks(try await WorkItemAPI.decodeList(from: Data(body.utf8)))
        let removal = TaskRemoval(window: .seconds(600), send: { _ in })
        removal.remove(try XCTUnwrap(split.current.first))
        XCTAssertEqual(removal.visible(split.current).map(\.id), ["b"])
        XCTAssertEqual(removal.visible(split.archived).map(\.id), ["c"], "positive control: the other tab is untouched")
        removal.undo()
        XCTAssertEqual(removal.visible(split.current).map(\.id), ["a", "b"])
    }

    func testTheTabsAreNamedAsAsked() {
        XCTAssertEqual(ParcelTasks.Tab.allCases.map(\.label), ["Текущи", "Архив"])
    }
}
