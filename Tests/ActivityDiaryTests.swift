import XCTest
@testable import Agrent

/// An activity's page of «Дневник на стопанството» (#516, agri-saas #2700):
/// its own route, never the treatment's БАБХ form, which has no row for a
/// cultivation and prints it as a spray with empty columns (agri-saas #2697).
@MainActor
final class ActivityDiaryTests: XCTestCase {

    func testTheRouteIsTheFarmDiaryNotTheBabhForm() {
        let path = ActivityAPI.diaryPath("tg 1")
        XCTAssertTrue(path.hasSuffix("/journal/activities/tg%201/campaign-diary"), path)
        XCTAssertFalse(path.contains("farm-record"))
        XCTAssertFalse(path.contains("?"), "the handle rides in the path, never a query")
    }

    /// The document flow asks for the activity's page when told it is an
    /// activity, and the treatment's pages otherwise.
    func testAnActivityDownloadsItsOwnPage() async {
        final class Asked: @unchecked Sendable { var handles: [String] = [] }
        let asked = Asked()
        let document = TreatmentDocument(activityDiary: { handle in
            asked.handles.append(handle)
            return URL(fileURLWithPath: "/tmp/fixture.pdf")
        })
        await document.download("tg_1", activity: true)
        XCTAssertEqual(asked.handles, ["tg_1"])
        XCTAssertEqual(document.document?.lastPathComponent, "fixture.pdf")
        XCTAssertNil(document.failure)
    }

    /// The entry screen offers the farm diary on other work and the БАБХ
    /// pages only on a spray or a fertilising, never both, never swapped.
    func testTheEntryOffersTheRightDocument() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Agrent/Journal/JournalDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("treatment.isApplication, treatment.isInBabhRegister"))
        XCTAssertTrue(source.contains("TreatmentDocumentButton(document: pdf, handle: handle, activity: true)"))
        XCTAssertTrue(source.contains("} else if let treatment, treatment.activityKind != nil,"),
                      "the farm diary is the else branch, so an entry never gets both")
    }
}
