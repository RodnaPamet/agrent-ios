import XCTest
@testable import Agrent

/// Задачи → «Още» → «Изтрий» for several tasks (#625, owner 2026-11-15).
/// Nothing here reaches the server: every send is a closure that records it.
@MainActor
final class TaskBulkRemovalTests: XCTestCase {

    @MainActor
    private final class Calls {
        var sent: [[String]] = []
        var refusal: Error?
    }

    private func bulk(_ calls: Calls) -> TaskBulkRemoval {
        TaskBulkRemoval(window: .seconds(600)) { ids in
            calls.sent.append(ids)
            if let refusal = calls.refusal { throw refusal }
            return ids.count
        }
    }

    private func row(_ mayDelete: Bool?) throws -> WorkItemSummary {
        let flag = mayDelete.map { ",\"mayDelete\":\($0)" } ?? ""
        return try APIClientTestDecoder.decode(WorkItemSummary.self, from: """
        {"id":"t1","key":"AGT-1","title":"Синтетична задача","type":"FIELD_OPERATION","status":"OPEN",
         "severity":"MEDIUM","dueAt":null,"assignee":null,"assigneeUserId":null,
         "createdAt":"2026-09-18T07:12:00.000Z","updatedAt":"2026-09-20T09:30:00.000Z"\(flag)}
        """)
    }

    func testTickingAndSelectAll() {
        let calls = Calls(), bulk = bulk(calls)
        bulk.start()
        XCTAssertTrue(bulk.selecting)
        bulk.toggle("t1")
        bulk.toggle("t2")
        bulk.toggle("t1")
        XCTAssertEqual(bulk.selected, ["t2"])
        bulk.selectAll(["t1", "t2", "t3"])
        XCTAssertEqual(bulk.selected, ["t1", "t2", "t3"])
        XCTAssertTrue(bulk.allSelected(["t1", "t2", "t3"]))
        bulk.selectAll(["t1", "t2", "t3"])
        XCTAssertTrue(bulk.selected.isEmpty, "a second «Избери всички» clears them")
        XCTAssertFalse(bulk.allSelected([]), "nothing to tick is not all ticked")
        bulk.toggle("t1")
        bulk.cancel()
        XCTAssertFalse(bulk.selecting)
        XCTAssertTrue(bulk.selected.isEmpty)
        XCTAssertTrue(calls.sent.isEmpty)
    }

    func testNothingTickedAsksNothing() {
        let bulk = bulk(Calls())
        bulk.start()
        bulk.ask()
        XCTAssertFalse(bulk.asking)
    }

    func testUndoInsideTheWindowSendsNothingAndKeepsTheTicks() async {
        let calls = Calls(), bulk = bulk(calls)
        bulk.start()
        bulk.selectAll(["t1", "t2"])
        bulk.ask()
        XCTAssertTrue(bulk.asking)
        bulk.confirm()
        XCTAssertEqual(bulk.hidden, ["t1", "t2"])
        XCTAssertEqual(bulk.pendingCount, 2)
        XCTAssertTrue(bulk.undoable)
        XCTAssertFalse(bulk.selecting)
        bulk.undo()
        XCTAssertTrue(bulk.hidden.isEmpty)
        XCTAssertTrue(bulk.selecting, "back to ticking, the ticks kept")
        XCTAssertEqual(bulk.selected, ["t1", "t2"])
        await bulk.commit()
        XCTAssertTrue(calls.sent.isEmpty)
    }

    func testTheWindowClosingSendsOneBatch() async {
        let calls = Calls(), bulk = bulk(calls)
        bulk.start()
        bulk.selectAll(["t2", "t1"])
        bulk.confirm()
        await bulk.commit()
        await bulk.commit()
        XCTAssertEqual(calls.sent, [["t1", "t2"]])
        XCTAssertEqual(bulk.batches, 1)
        XCTAssertFalse(bulk.showsFailure)
        XCTAssertEqual(bulk.hidden, ["t1", "t2"], "hidden until the list reads again")
        bulk.listRead()
        XCTAssertTrue(bulk.hidden.isEmpty)
    }

    /// All or nothing (owner ruling): a refusal deleted nothing, so every
    /// task comes back, still ticked, with the server's count said.
    func testARefusalBringsEveryTaskBackStillTicked() async throws {
        let calls = Calls(), bulk = bulk(calls)
        calls.refusal = APIClient.APIError.http(status: 409, code: "TASK_BELONGS_TO_TREATMENT", message: "x",
                                                params: ["refused": "1", "selected": "3"])
        bulk.start()
        bulk.selectAll(["t1", "t2", "t3"])
        bulk.confirm()
        await bulk.commit()
        XCTAssertTrue(bulk.hidden.isEmpty)
        XCTAssertTrue(bulk.selecting)
        XCTAssertEqual(bulk.selected, ["t1", "t2", "t3"])
        XCTAssertEqual(bulk.batches, 0)
        XCTAssertEqual(bulk.failure,
                       "Нищо не е изтрито: 1 от 3 избрани задачи са част от записано мероприятие в Дневника. Махнете ги от избора и опитайте пак.")
    }

    func testTheCountIsSaidForEitherRefusal() {
        let text = UserMessage.text(for: APIClient.APIError.http(status: 403, code: "TASK_DELETE_NOT_PERMITTED", message: "x",
                                                                 params: ["refused": "2", "selected": "5"]))
        XCTAssertEqual(text, "Нищо не е изтрито: 2 от 5 избрани задачи са създадени от друг човек. Махнете ги от избора и опитайте пак.")
        let single = UserMessage.text(for: APIClient.APIError.http(status: 403, code: "TASK_DELETE_NOT_PERMITTED", message: "x"))
        XCTAssertTrue(single.hasPrefix("Само човекът, създал тази задача"), "the single delete keeps its sentence")
    }

    /// Only a row that says yes outright: one doubtful row would stop the
    /// whole call.
    func testOnlyAnExplicitYesIsTickable() throws {
        let me = CurrentUser(id: "u", name: nil, email: nil, role: nil,
                             permissions: CurrentUser.Permissions(canWrite: true, canAdmin: false))
        XCTAssertTrue(TaskBulkRemoval.offered(try row(true), to: me))
        XCTAssertFalse(TaskBulkRemoval.offered(try row(false), to: me))
        XCTAssertFalse(TaskBulkRemoval.offered(try row(nil), to: me), "a row from before the field")
        XCTAssertTrue(TaskRemoval.offered(try row(nil), to: me), "positive control: the swipe still offers it")
    }

    func testAtMostAHundred() {
        let bulk = bulk(Calls())
        bulk.start()
        let ids = (0..<130).map { "t\($0)" }
        bulk.selectAll(ids)
        XCTAssertEqual(bulk.selected.count, 100)
        XCTAssertTrue(bulk.allSelected(ids))
        bulk.toggle("t120")
        XCTAssertEqual(bulk.selected.count, 100, "no 101st")
        XCTAssertEqual(WorkItemAPI.bulkDeletePath.hasSuffix("/tasks/bulk/delete"), true)
    }

    func testTheWords() {
        XCTAssertEqual(TaskBulkRemoval.confirmTitle(1), "Да се изтрие ли 1 задача?")
        XCTAssertEqual(TaskBulkRemoval.confirmTitle(4), "Да се изтрият ли 4 задачи?")
        XCTAssertEqual(TaskBulkRemoval.deleteButton(0), "Изтрий")
        XCTAssertEqual(TaskBulkRemoval.deleteButton(3), "Изтрий (3)")
        XCTAssertEqual(TaskBulkRemoval.removedText(2), "Изтрити: 2 задачи.")
        XCTAssertTrue(TaskBulkRemoval.announcement(2).contains("«Отмени»"))
        XCTAssertFalse((TaskBulkRemoval.confirmMessage + TaskBulkRemoval.announcement(2)).contains("завинаги"),
                       "the server soft-deletes; nothing promises otherwise")
        for text in [TaskBulkRemoval.confirmTitle(4), TaskBulkRemoval.confirmMessage, TaskBulkRemoval.announcement(2),
                     TaskBulkRemoval.selectAllTitle, TaskBulkRemoval.clearAllTitle] {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }
}
