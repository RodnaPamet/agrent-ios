import XCTest
@testable import Agrent

/// «Нова задача» (#372): what the form asks before «Създай», and the body
/// it sends. Synthetic titles and people.
final class NewTaskTests: XCTestCase {
    func testATitleIsAllItNeeds() {
        var draft = NewTaskDraft()
        XCTAssertEqual(draft.problem, "Въведете заглавие.")
        draft.title = "   "
        XCTAssertEqual(draft.problem, "Въведете заглавие.", "blank is no title")
        draft.title = "Почистване на канала"
        XCTAssertNil(draft.problem)
        draft.title = String(repeating: "я", count: NewTaskAPI.titleMaxLength + 1)
        XCTAssertEqual(draft.problem, "Заглавието е твърде дълго — до 500 знака.")
    }

    /// The web's defaults, nothing blank, and no due day unless asked.
    func testTheBodyIsTheWebsShapeWithNothingBlank() throws {
        var draft = NewTaskDraft()
        draft.title = "  Почистване на канала "
        draft.details = "  "
        let sent = try body(draft)
        XCTAssertEqual(sent["title"] as? String, "Почистване на канала")
        XCTAssertEqual(sent["type"] as? String, "TASK")
        XCTAssertEqual(sent["severity"] as? String, "MEDIUM")
        XCTAssertNil(sent["description"], "a blank description isn't sent")
        XCTAssertNil(sent["dueAt"])
        XCTAssertNil(sent["assigneeUserId"], "«Без изпълнител» sends none")
        XCTAssertNil(sent["priority"], "no priority (owner, 2026-10-09)")
    }

    /// A due DAY, as the web's `ymdToInstant` sends it: UTC midnight of the
    /// day picked, in the phone's own zone.
    func testADueDayIsUTCMidnightOfThatDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15)))
        XCTAssertEqual(BgDate.dueInstant(day), "2026-10-21T00:00:00.000Z")

        var draft = NewTaskDraft(due: day)
        draft.title = "Задача"
        draft.hasDue = true
        draft.assigneeID = "u-op"
        draft.details = " Да се провери и северният край. "
        let sent = try body(draft)
        XCTAssertEqual(sent["dueAt"] as? String, "2026-10-21T00:00:00.000Z")
        XCTAssertEqual(sent["assigneeUserId"] as? String, "u-op")
        XCTAssertEqual(sent["description"] as? String, "Да се провери и северният край.")
    }

    func testTheRouteIsTheTaskList() {
        XCTAssertEqual(NewTaskAPI.path, WorkItemAPI.listPath)
        XCTAssertTrue(NewTaskView.unsureNote.hasSuffix("."))
    }

    private func body(_ draft: NewTaskDraft) throws -> [String: Any] {
        let data = try JSONEncoder().encode(draft.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
