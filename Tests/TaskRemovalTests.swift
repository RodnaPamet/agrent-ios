import XCTest
@testable import Agrent

/// A Задачи row's «Изтрий», its question and its five seconds of «Отмени»
/// (#454; agri-saas #2396). Nothing here reaches the server: every send is a
/// closure that records what it was asked.
@MainActor
final class TaskRemovalTests: XCTestCase {

    private func me(canWrite: Bool = true) -> CurrentUser {
        CurrentUser(id: "u", name: nil, email: nil, role: nil,
                    permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: false))
    }

    private func row(_ id: String = "t1", mayDelete: String? = "true") throws -> WorkItemSummary {
        let flag = mayDelete.map { #","mayDelete":\#($0)"# } ?? ""
        return try JSONDecoder().decode(WorkItemSummary.self, from: Data(
            #"{"id":"\#(id)","key":"T-1","title":"Синтетична задача","type":"TASK","status":"OPEN"\#(flag)}"#.utf8))
    }

    @MainActor
    private final class Calls {
        var log: [String] = []
        var refusal: Error?
    }

    private func removal(_ calls: Calls, window: Duration = .seconds(600)) -> TaskRemoval {
        TaskRemoval(window: window,
                    send: { id in
                        calls.log.append("send \(id)")
                        if let refusal = calls.refusal { throw refusal }
                    },
                    changed: { calls.log.append("changed") })
    }

    // MARK: - Who is offered «Изтрий»

    /// The server's own answer for this person; only an explicit "no" hides
    /// it (backend 1: a stale "no" costs a farmer their own task).
    func testTheRowsFlagDecides() throws {
        XCTAssertTrue(TaskRemoval.offered(try row(mayDelete: "true"), to: me()))
        XCTAssertFalse(TaskRemoval.offered(try row(mayDelete: "false"), to: me()))
        XCTAssertTrue(TaskRemoval.offered(try row(mayDelete: nil), to: me()), "a row from before the field")
        XCTAssertFalse(TaskRemoval.offered(try row(mayDelete: "true"), to: me(canWrite: false)), "a reader")
        XCTAssertFalse(TaskRemoval.offered(try row(mayDelete: "true"), to: nil))
    }

    /// An odd value costs the flag, never the row, nor the list.
    func testAnOddFlagCostsOnlyTheFlag() throws {
        let odd = try row(mayDelete: #""yes""#)
        XCTAssertNil(odd.mayDelete)
        XCTAssertEqual(odd.title, "Синтетична задача", "positive control: the rest of the row read")
        XCTAssertNil(try row(mayDelete: "null").mayDelete)
        XCTAssertEqual(try row(mayDelete: "false").mayDelete, false)
    }

    func testTheQuestionNamesATask() {
        XCTAssertEqual(TaskRemoval.confirmTitle, "Сигурни ли сте, че искате да изтриете задачата?")
    }

    // MARK: - The five seconds

    /// Hidden at once, sent only after the window; «Отмени» inside it sends
    /// nothing at all.
    func testUndoSendsNothing() throws {
        let calls = Calls()
        let store = removal(calls)
        store.remove(try row())
        XCTAssertEqual(store.hidden, ["t1"])
        XCTAssertEqual(store.undoable?.title, "Синтетична задача")
        store.undo()
        XCTAssertEqual(store.hidden, [])
        XCTAssertNil(store.undoable)
        XCTAssertEqual(calls.log, [])
    }

    func testTheWindowSendsItOnce() async throws {
        let calls = Calls()
        let store = removal(calls)
        store.remove(try row())
        await store.commit("t1")
        await store.commit("t1")
        XCTAssertEqual(calls.log, ["send t1", "changed"])
        XCTAssertEqual(store.deletions, 1)
        XCTAssertNil(store.undoable)
        store.listRead()
        XCTAssertEqual(store.hidden, [], "a fresh read no longer lists it")
    }

    /// A refusal brings the row back, with the server's sentence.
    func testARefusalBringsTheRowBack() async throws {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 403, code: "TASK_DELETE_NOT_PERMITTED", message: nil)
        let store = removal(calls)
        store.remove(try row())
        await store.commit("t1")
        XCTAssertEqual(store.hidden, [])
        XCTAssertEqual(store.failure, UserMessage.bulgarian["TASK_DELETE_NOT_PERMITTED"])
        XCTAssertEqual(store.deletions, 0)
    }

    /// Already gone, from the web or another phone: done, not refused.
    func testAlreadyGoneIsDone() async throws {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 404, code: "TASK_NOT_FOUND", message: nil)
        let store = removal(calls)
        store.remove(try row())
        await store.commit("t1")
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.deletions, 1)
    }

    /// A second confirmed delete inside the window sends the first at once:
    /// the bar names one task.
    func testASecondDeleteSendsTheFirst() async throws {
        let calls = Calls()
        let store = removal(calls)
        store.remove(try row("t1"))
        store.remove(try row("t2"))
        XCTAssertEqual(store.undoable?.id, "t2")
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(calls.log.first, "send t1")
    }

    func testTheRefusalsAreBulgarian() {
        for code in ["TASK_DELETE_NOT_PERMITTED", "TASK_BELONGS_TO_TREATMENT"] {
            let text = UserMessage.bulgarian[code]
            XCTAssertNotNil(text, code)
            XCTAssertTrue(text?.hasSuffix(".") == true, code)
        }
    }
}
