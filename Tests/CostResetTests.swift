import XCTest
@testable import Agrent

/// The calculator's «Нулирай» (#610, owner 2026-11-15): the question with
/// the count and the total, five seconds of «Отмени», then one bulk delete
/// (agri-saas #3071). Nothing here reaches the server: every send is a
/// closure that records it was called.
@MainActor
final class CostResetTests: XCTestCase {

    private func me(canWrite: Bool = true, canAdmin: Bool) -> CurrentUser {
        CurrentUser(id: "u", name: nil, email: nil, role: nil,
                    permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: canAdmin))
    }

    @MainActor
    private final class Calls {
        var sends = 0
        var refusal: Error?
    }

    private func reset(_ calls: Calls) -> CostReset {
        CostReset(window: .seconds(600), send: {
            calls.sends += 1
            if let refusal = calls.refusal { throw refusal }
            return 3
        })
    }

    private let scope = CostReset.Scope(count: 3, total: "1 250,00 EUR")

    // MARK: - Who and what

    /// The route's rule: owner or admin, not anyone who may write.
    func testOfferedToTheOwnerOrAnAdminOnly() {
        XCTAssertTrue(CostReset.offered(to: me(canAdmin: true)))
        XCTAssertFalse(CostReset.offered(to: me(canAdmin: false)), "a member who may write")
        XCTAssertFalse(CostReset.offered(to: nil))
    }

    func testThePathIsTheRegisterItself() {
        XCTAssertTrue(CostsAPI.listPath.hasSuffix("/grain/costs"), CostsAPI.listPath)
    }

    /// The question counts and sums every cost the summary has, every type
    /// and currency, never one total across currencies.
    func testTheScopeComesFromTheSummary() {
        let summary = CostSummary(byType: [
            .init(category: .fuel, currency: "EUR", totalMinor: 100_000, count: 2),
            .init(category: .payroll, currency: "EURO", totalMinor: 25_000, count: 1),
            .init(category: .payroll, currency: "BGN", totalMinor: 2_000, count: 1),
        ], byTypeAndMonth: [])
        let scope = CostReset.scope(summary, listed: 99)
        XCTAssertEqual(scope.count, 4, "the summary's count, not the list's")
        let total = try? XCTUnwrap(scope.total)
        XCTAssertEqual(total?.components(separatedBy: " и ").count, 2, total ?? "")
        XCTAssertTrue(total?.contains("EUR") ?? false)
        XCTAssertTrue(total?.contains("BGN") ?? false)

        let bare = CostReset.scope(nil, listed: 7)
        XCTAssertEqual(bare, CostReset.Scope(count: 7, total: nil), "no summary: the count alone")
    }

    func testTheWordsArePlainBulgarian() {
        XCTAssertEqual(CostReset.confirmTitle, "Да се изтрият ли всички разходи на стопанството?")
        XCTAssertEqual(CostReset.message(scope), "3 разхода, общо 1 250,00 EUR. Калкулаторът ще започне от нула.")
        XCTAssertEqual(CostReset.message(.init(count: 1, total: nil)), "1 разход. Калкулаторът ще започне от нула.")
        XCTAssertEqual(CostReset.removedText(scope), "Изтрити: 3 разхода.")
        XCTAssertTrue(CostReset.announcement(scope).contains("«Отмени»"))
        for text in [CostReset.confirmTitle, CostReset.message(scope), CostReset.announcement(scope)] {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }

    // MARK: - The window

    func testTheQuestionComesFirstAndSendsNothing() {
        let calls = Calls()
        let reset = reset(calls)
        reset.ask(scope)
        XCTAssertTrue(reset.asking)
        XCTAssertEqual(reset.scope, scope)
        XCTAssertFalse(reset.hidesCosts, "asking hides nothing")
        XCTAssertEqual(calls.sends, 0)
    }

    func testUndoInsideTheWindowSendsNothing() async {
        let calls = Calls()
        let reset = reset(calls)
        reset.ask(scope)
        reset.confirm()
        XCTAssertTrue(reset.hidesCosts)
        XCTAssertTrue(reset.undoable)
        reset.undo()
        XCTAssertFalse(reset.hidesCosts)
        XCTAssertFalse(reset.undoable)
        await reset.commit()
        XCTAssertEqual(calls.sends, 0, "«Отмени» leaves nothing to send")
    }

    func testTheWindowClosingSendsOnceAndAsksForARead() async {
        let calls = Calls()
        let reset = reset(calls)
        reset.confirm()
        await reset.commit()
        await reset.commit()
        XCTAssertEqual(calls.sends, 1)
        XCTAssertEqual(reset.resets, 1)
        XCTAssertTrue(reset.hidesCosts, "hidden until the list reads again")
        XCTAssertFalse(reset.undoable, "too late for «Отмени»")
        reset.listRead()
        XCTAssertFalse(reset.hidesCosts)
    }

    func testTheTimerSends() async throws {
        let calls = Calls()
        let reset = CostReset(window: .milliseconds(20), send: { calls.sends += 1; return 0 })
        reset.confirm()
        for _ in 0..<100 where reset.resets == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.sends, 1)
    }

    /// A refusal brings the costs back and says why, in Bulgarian.
    func testARefusalBringsTheCostsBack() async {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 403, code: "ADMIN_FORBIDDEN_FOR_ROLE", message: "Forbidden")
        let reset = reset(calls)
        reset.confirm()
        await reset.commit()
        XCTAssertFalse(reset.hidesCosts)
        XCTAssertTrue(reset.showsFailure)
        XCTAssertEqual(reset.resets, 0)
        let failure = reset.failure ?? ""
        XCTAssertNotNil(failure.range(of: "\\p{Cyrillic}", options: .regularExpression), failure)
        reset.dismissFailure()
        XCTAssertFalse(reset.showsFailure)
    }
}
