import XCTest
@testable import Agrent

/// Pruning, cultivation, sowing and harvest share the journal row with the
/// treatments (agri-saas #2339, owner 2026-10-25). Only a treatment gets a
/// treatment's controls.
@MainActor
final class ActivityRowTests: XCTestCase {

    private func entry(kind: String?, mayCorrect: Bool? = nil) -> LogEntry {
        LogEntry(id: "e", type: .activity, status: .done, title: "Резитба", occurredAt: nil,
                 treatment: JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 2, kind: kind,
                                             mayDelete: true, mayCorrect: mayCorrect))
    }

    private let writer = CurrentUser(id: "u", name: nil, email: nil, role: nil,
                                     permissions: CurrentUser.Permissions(canWrite: true, canAdmin: true))

    func testATreatmentKeepsItsControls() {
        for kind in ["SPRAY", "FERTILIZE", nil] {
            let row = entry(kind: kind)
            XCTAssertTrue(row.treatment?.isChemicalTreatment == true, kind ?? "nil")
            XCTAssertTrue(TreatmentCorrection.offered(row, to: writer), kind ?? "nil")
            XCTAssertTrue(TreatmentRemoval.offered(row, to: writer), kind ?? "nil")
        }
    }

    /// The correction route refuses it (`NOT_A_TREATMENT`) and the withdrawal
    /// isn't settled for one, so neither is offered, whatever the flags say.
    func testOtherWorkGetsNone() {
        for kind in ["PRUNE", "CULTIVATE", "SEED", "HARVEST", "SOMETHING_NEW"] {
            let row = entry(kind: kind, mayCorrect: true)
            XCTAssertFalse(row.treatment?.isChemicalTreatment == true, kind)
            XCTAssertFalse(TreatmentCorrection.offered(row, to: writer), kind)
            XCTAssertFalse(TreatmentRemoval.offered(row, to: writer), kind)
        }
    }

    func testTheAreaIsNamedForTheWork() throws {
        func label(_ kind: String?) throws -> String {
            JournalDetailView.areaLabel(try XCTUnwrap(entry(kind: kind).treatment))
        }
        XCTAssertEqual(try label("SPRAY"), "Третирана площ")
        XCTAssertEqual(try label("FERTILIZE"), "Наторена площ")
        XCTAssertEqual(try label(nil), "Третирана площ")
        XCTAssertEqual(try label("PRUNE"), "Площ")
    }
}
