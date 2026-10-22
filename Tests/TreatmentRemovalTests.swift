import XCTest
@testable import Agrent

/// A Дневник row's «Изтрий», its five seconds of «Отмени», and «Кошче»
/// (#395; agri-saas #2184). Nothing here reaches the server: every send is
/// a closure that records what it was asked.
@MainActor
final class TreatmentRemovalTests: XCTestCase {

    private func me(id: String, canWrite: Bool = true, canAdmin: Bool = false) -> CurrentUser {
        CurrentUser(id: id, name: nil, email: nil, role: nil,
                    permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: canAdmin))
    }

    private func entry(_ handle: String? = "tg_1", parcels: Int = 3, creator: String? = nil,
                       product: String = "Препарат А") -> LogEntry {
        LogEntry(id: "e_\(handle ?? "none")", type: .inputApplication, status: .done,
                 title: "\(product) — Парцел 1", occurredAt: nil,
                 treatment: JournalTreatment(treatmentGroupId: handle, productName: product,
                                             parcelCount: parcels, createdByUserId: creator))
    }

    /// What the store asked of the server and the outbox, in order.
    @MainActor
    private final class Calls {
        var log: [String] = []
        var refusal: Error?
    }

    private func removal(_ calls: Calls, window: Duration = .seconds(600)) -> TreatmentRemoval {
        TreatmentRemoval(
            window: window,
            send: { handle in
                calls.log.append("send \(handle)")
                if let refusal = calls.refusal { throw refusal }
            },
            forget: { calls.log.append("forget \($0)") },
            changed: { calls.log.append("changed") })
    }

    // MARK: - Who is offered «Изтрий»

    func testOfferedToTheCreatorAndAnAdministrator() {
        let row = entry(creator: "u_creator")
        XCTAssertTrue(TreatmentRemoval.offered(row, to: me(id: "u_creator")))
        XCTAssertTrue(TreatmentRemoval.offered(row, to: me(id: "u_other", canAdmin: true)))
        XCTAssertFalse(TreatmentRemoval.offered(row, to: me(id: "u_other")),
                       "a writer who did not record it is refused by the server")
    }

    func testNeverOfferedToARoleThatCannotWrite() {
        XCTAssertFalse(TreatmentRemoval.offered(entry(creator: "u_reader"), to: me(id: "u_reader", canWrite: false)))
        XCTAssertFalse(TreatmentRemoval.offered(entry(), to: nil), "nobody known, nothing offered")
    }

    /// #2184 as first written sends no creator. The server decides then.
    func testWithoutACreatorOfferedToAnyWriter() {
        XCTAssertTrue(TreatmentRemoval.offered(entry(creator: nil), to: me(id: "u_any")))
    }

    func testAnEntryThatIsNoTreatmentHasNoSwipe() {
        XCTAssertFalse(TreatmentRemoval.offered(entry(parcels: 0), to: me(id: "u", canAdmin: true)),
                       "an entry folded to itself is one parcel's row, not a treatment")
        XCTAssertFalse(TreatmentRemoval.offered(entry(nil), to: me(id: "u", canAdmin: true)),
                       "no handle, nothing to address the delete to")
        XCTAssertTrue(TreatmentRemoval.offered(entry(), to: me(id: "u", canAdmin: true)), "positive control")
    }

    // MARK: - The window

    func testASwipeHidesTheRowAndSendsNothingYet() {
        let calls = Calls()
        let store = removal(calls)
        let row = entry()
        store.remove(row)
        XCTAssertTrue(store.isHidden(row))
        XCTAssertEqual(store.undoable, .init(handle: "tg_1", title: row.displayTitle))
        XCTAssertEqual(calls.log, [], "nothing goes before the window closes")
    }

    /// The window's end, run by hand after «Отмени»: a timer that slipped
    /// its cancellation would reach exactly this and must find nothing to send.
    func testUndoBringsItBackAndNothingIsEverSent() async {
        let calls = Calls()
        let store = removal(calls)
        let row = entry()
        store.remove(row)
        store.undo()
        XCTAssertFalse(store.isHidden(row))
        XCTAssertNil(store.undoable)
        await store.commit("tg_1")
        XCTAssertEqual(calls.log, [], "an undone removal sent nothing")
    }

    /// The web's five seconds, and longer where reaching «Отмени» takes
    /// several moves (VoiceOver, Switch Control).
    func testTheWindowIsTheWebsAndLongerUnderAssistiveTechnology() {
        XCTAssertEqual(TreatmentRemoval.window, .seconds(5))
        XCTAssertGreaterThan(TreatmentRemoval.assistedWindow, TreatmentRemoval.window)
        XCTAssertTrue(TreatmentRemoval.announcement("Препарат А").contains("Кошче"),
                      "the spoken sentence names the way back that doesn't run out")
    }

    func testTheWindowClosingSendsItAndDropsThePhonesCopy() async throws {
        let calls = Calls()
        let store = removal(calls)
        let row = entry()
        store.remove(row, window: .milliseconds(20))
        for _ in 0..<100 where calls.log.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(calls.log, ["send tg_1", "forget tg_1", "changed"])
        XCTAssertNil(store.undoable)
        XCTAssertTrue(store.isHidden(row), "hidden until a fresh read, which a cached page may not be")
    }

    func testASecondSwipeSendsTheFirstAtOnce() async throws {
        let calls = Calls()
        let store = removal(calls)
        store.remove(entry("tg_1"))
        store.remove(entry("tg_2", product: "Препарат Б"))
        XCTAssertEqual(store.undoable?.handle, "tg_2", "the bar names the latest")
        for _ in 0..<100 where calls.log.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(calls.log, ["send tg_1", "forget tg_1", "changed"],
                       "«Отмени» must never stand for a treatment the bar does not name")
        store.undo()
        XCTAssertFalse(store.isHidden(entry("tg_2")))
    }

    // MARK: - The server's answer

    func testARefusalBringsTheRowBackWithTheServersSentence() async {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 403, code: "TREATMENT_DELETE_NOT_PERMITTED", message: nil)
        let store = removal(calls)
        let row = entry()
        store.remove(row)
        await store.commit("tg_1")
        XCTAssertFalse(store.isHidden(row))
        XCTAssertEqual(store.failure, UserMessage.text(for: calls.refusal!))
        XCTAssertEqual(calls.log, ["send tg_1"], "a refused delete keeps the phone's copy")
        XCTAssertTrue(store.failure?.contains("администратор") ?? false)
    }

    func testAlreadyGoneCountsAsDone() async {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 404, code: "TREATMENT_NOT_FOUND", message: nil)
        let store = removal(calls)
        store.remove(entry())
        await store.commit("tg_1")
        XCTAssertNil(store.failure)
        XCTAssertEqual(calls.log, ["send tg_1", "forget tg_1", "changed"])
    }

    func testAFreshReadShowsWhatTheServerLists() async {
        let calls = Calls()
        let store = removal(calls)
        store.remove(entry("tg_sent"))
        await store.commit("tg_sent")
        store.remove(entry("tg_waiting"))
        store.listRead()
        XCTAssertFalse(store.isHidden(entry("tg_sent")), "the list's own answer stands once it has one")
        XCTAssertTrue(store.isHidden(entry("tg_waiting")), "a row inside its window stays hidden")
    }

    func testARestoreFromTheTrashShowsItAgain() async {
        let calls = Calls()
        let store = removal(calls)
        store.remove(entry())
        await store.commit("tg_1")
        store.restored("tg_1")
        XCTAssertFalse(store.isHidden(entry()))
    }

    // MARK: - «Кошче»

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json"))
    }

    func testTheTrashReadsBothShapes() throws {
        let rows = try TreatmentTrashAPI.decodeList(from: fixture("treatments-deleted"))
        XCTAssertEqual(rows.map(\.id), ["tg_fixture_deleted_1", "tg_fixture_deleted_2"])
        let full = rows[0]
        XCTAssertEqual(TrashRow.title(full), "Препарат Тест 250 ЕК")
        XCTAssertNotNil(full.deletedAt)
        XCTAssertEqual(full.blockNames, ["Блок Север", "Блок Юг"])
        XCTAssertEqual(TrashRow.lines(full).count, 3, "done, where, removed")

        let bare = rows[1]
        XCTAssertEqual(TrashRow.title(bare), "Мероприятие", "only the handle and the dates")
        XCTAssertEqual(TrashRow.lines(bare).count, 2, "done, removed")
    }

    func testOneOddRowCostsOnlyItself() throws {
        let body = """
        {"treatments": [
          {"treatmentGroupId": "tg_a", "deletedAt": "not a date", "taskCount": "two",
           "occurredOn": null, "deletedByUserId": null, "blockNames": "Блок"},
          {"deletedAt": "2026-10-21T08:30:00.000Z", "taskCount": 1},
          {"treatmentGroupId": "tg_b", "deletedAt": "2026-10-21T08:30:00Z", "taskCount": 1,
           "occurredOn": "2026-10-20", "deletedByUserId": null, "kind": "FERTILIZE"}
        ]}
        """
        let rows = try TreatmentTrashAPI.decodeList(from: Data(body.utf8))
        XCTAssertEqual(rows.map(\.id), ["tg_a", "tg_b"], "a row with no handle cannot be restored, so it alone goes")
        XCTAssertNil(rows[0].deletedAt)
        XCTAssertEqual(rows[0].blockNames, [])
        XCTAssertEqual(TrashRow.title(rows[1]), "Торене")
    }

    func testTheRoutesAreTheTreatmentsOwn() {
        XCTAssertTrue(TreatmentTrashAPI.deletedPath.hasSuffix("/journal/treatments/deleted"))
        XCTAssertTrue(TreatmentTrashAPI.restorePath("tg 1").hasSuffix("/journal/treatments/tg%201/restore"))
    }

    func testTheRefusalsAreBulgarian() {
        for code in ["TREATMENT_DELETE_NOT_PERMITTED", "TREATMENT_MIXED_AUTHORSHIP"] {
            let text = UserMessage.text(for: APIClient.APIError.http(status: 403, code: code, message: "English"))
            XCTAssertFalse(text.contains("English"), code)
            XCTAssertTrue(text.hasSuffix("."), code)
        }
    }
}
