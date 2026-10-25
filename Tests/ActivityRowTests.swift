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
            XCTAssertTrue(row.treatment?.isApplication == true, kind ?? "nil")
            XCTAssertTrue(TreatmentCorrection.offered(row, to: writer), kind ?? "nil")
            XCTAssertTrue(TreatmentRemoval.offered(row, to: writer), kind ?? "nil")
        }
    }

    /// The correction route refuses it (`NOT_A_TREATMENT`), so it isn't
    /// offered, whatever the flags say. The withdrawal removes it like a
    /// treatment, so «Изтрий» is, on the same `mayDelete`.
    func testOtherWorkIsDeletedButNotCorrected() {
        for kind in ["PRUNE", "CULTIVATE", "HARVEST", "SOMETHING_NEW"] {
            let row = entry(kind: kind, mayCorrect: true)
            XCTAssertFalse(row.treatment?.isApplication == true, kind)
            XCTAssertFalse(TreatmentCorrection.offered(row, to: writer), kind)
            XCTAssertTrue(TreatmentRemoval.offered(row, to: writer), kind)
        }
    }

    /// A sowing is an application with a seed (agri-saas #2368): correctable
    /// like a treatment, but never in a БАБХ table, so no ДНЕВНИК page.
    func testASowingIsCorrectedButHasNoBabhPage() throws {
        let row = try XCTUnwrap(entry(kind: "SEED", mayCorrect: true).treatment)
        XCTAssertTrue(row.isApplication)
        XCTAssertFalse(row.isInBabhRegister)
        XCTAssertTrue(TreatmentCorrection.offered(entry(kind: "SEED", mayCorrect: true), to: writer))
        for kind in ["SPRAY", "FERTILIZE", nil] {
            XCTAssertTrue(try XCTUnwrap(entry(kind: kind).treatment).isInBabhRegister, kind ?? "nil")
        }
        XCTAssertFalse(try XCTUnwrap(entry(kind: "PRUNE").treatment).isInBabhRegister)
    }

    func testTheAreaIsNamedForTheWork() throws {
        func label(_ kind: String?) throws -> String {
            JournalDetailView.areaLabel(try XCTUnwrap(entry(kind: kind).treatment))
        }
        XCTAssertEqual(try label("SPRAY"), "Третирана площ")
        XCTAssertEqual(try label("FERTILIZE"), "Наторена площ")
        XCTAssertEqual(try label(nil), "Третирана площ")
        XCTAssertEqual(try label("PRUNE"), "Площ")
        XCTAssertEqual(try label("SEED"), "Засята площ")
    }
}
