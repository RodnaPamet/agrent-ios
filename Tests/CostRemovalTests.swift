import XCTest
@testable import Agrent

/// A «Разходи» row's «Изтрий», its question and its five seconds of
/// «Отмени» (#481, owner 2026-10-31). Nothing here reaches the server: every
/// send is a closure that records what it was asked.
@MainActor
final class CostRemovalTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "costs-list", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func costs() async throws -> [CostEntry] {
        try await CostsAPI.decodeList(from: fixture()).items
    }

    private func me(canWrite: Bool = true) -> CurrentUser {
        CurrentUser(id: "u", name: nil, email: nil, role: nil,
                    permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: false))
    }

    @MainActor
    private final class Calls {
        var log: [String] = []
        var refusal: Error?
    }

    private func removal(_ calls: Calls) -> CostRemoval {
        CostRemoval(window: .seconds(600), send: { id in
            calls.log.append("send \(id)")
            if let refusal = calls.refusal { throw refusal }
        })
    }

    // MARK: - Who and what

    /// The route's rule: anyone who may write.
    func testOfferedToWhoeverMayWrite() {
        XCTAssertTrue(CostRemoval.offered(to: me()))
        XCTAssertFalse(CostRemoval.offered(to: me(canWrite: false)), "a reader")
        XCTAssertFalse(CostRemoval.offered(to: nil))
    }

    /// The question and the bar name the expense as its row reads: kind,
    /// amount, day — in Bulgarian.
    func testTheWordsNameTheExpense() async throws {
        let all = try await costs()
        let cost = try XCTUnwrap(all.first)
        let label = CostRemoval.label(cost)
        XCTAssertTrue(label.hasPrefix(cost.category.label), label)
        XCTAssertTrue(label.contains(cost.amountText), label)
        XCTAssertTrue(label.contains(BgDate.dayMonth(cost.incurredOn)), label)
        XCTAssertEqual(CostRemoval.confirmTitle, "Сигурни ли сте, че искате да изтриете разхода?")
        let undoable = CostRemoval.Undoable(id: cost.id, label: label)
        XCTAssertTrue(CostRemoval.announcement(undoable).contains("«Отмени»"))
    }

    func testThePathIsTheEntrysOwn() {
        XCTAssertTrue(CostsAPI.entryPath("c 1").hasSuffix("/grain/costs/c%201"))
    }

    // MARK: - The five seconds

    func testUndoSendsNothing() async throws {
        let calls = Calls()
        let store = removal(calls)
        let all = try await costs()
        let cost = try XCTUnwrap(all.first)
        store.remove(cost)
        XCTAssertEqual(store.hidden, [cost.id])
        XCTAssertEqual(store.visible(all).count, all.count - 1)
        store.undo()
        XCTAssertEqual(store.hidden, [])
        XCTAssertEqual(store.visible(all).count, all.count)
        XCTAssertEqual(calls.log, [])
    }

    func testTheWindowSendsItOnce() async throws {
        let calls = Calls()
        let store = removal(calls)
        let all = try await costs()
        let cost = try XCTUnwrap(all.first)
        store.remove(cost)
        await store.commit(cost.id)
        await store.commit(cost.id)
        XCTAssertEqual(calls.log, ["send \(cost.id)"])
        XCTAssertEqual(store.deletions, 1)
        store.listRead()
        XCTAssertEqual(store.hidden, [], "a fresh read no longer lists it")
    }

    func testARefusalBringsTheRowBack() async throws {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 403, code: "FORBIDDEN", message: "Forbidden")
        let store = removal(calls)
        let all = try await costs()
        let cost = try XCTUnwrap(all.first)
        store.remove(cost)
        await store.commit(cost.id)
        XCTAssertEqual(store.hidden, [])
        XCTAssertTrue(store.showsFailure)
        XCTAssertTrue(UserMessage.isBulgarianSentence(store.failure ?? ""), store.failure ?? "")
        XCTAssertEqual(store.deletions, 0)
    }

    /// Already gone, from the web or another phone: done, not refused.
    func testAlreadyGoneIsDone() async throws {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 404, code: "COST_ENTRY_NOT_FOUND", message: nil)
        let store = removal(calls)
        let all = try await costs()
        let cost = try XCTUnwrap(all.first)
        store.remove(cost)
        await store.commit(cost.id)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.deletions, 1)
    }

    func testASecondDeleteSendsTheFirst() async throws {
        let calls = Calls()
        let store = removal(calls)
        let all = try await costs()
        store.remove(all[0])
        store.remove(all[1])
        XCTAssertEqual(store.undoable?.id, all[1].id)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(calls.log.first, "send \(all[0].id)")
    }
}
