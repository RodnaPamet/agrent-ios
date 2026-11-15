import XCTest
@testable import Agrent

/// A parcel's history opens Дневник's own «Нов запис» (#608), on that parcel,
/// and every step has «Назад» (#609). Nothing here records anything.
final class HistoryEntryFlowTests: XCTestCase {

    private let crops = [
        TreatmentPlace.Crop(key: "пшеница", label: "Пшеница", values: ["WHEAT", "Winter Wheat"], parcelCount: 3),
        TreatmentPlace.Crop(key: "слънчоглед", label: "Слънчоглед", values: ["SUNFLOWER"], parcelCount: 1),
    ]

    @MainActor func testTheParcelsCropIsChosenCaseBlind() {
        XCTAssertEqual(TreatmentEntryFlow.crop(holding: "wheat", in: crops)?.key, "пшеница")
        XCTAssertEqual(TreatmentEntryFlow.crop(holding: "Winter Wheat", in: crops)?.key, "пшеница")
        XCTAssertEqual(TreatmentEntryFlow.crop(holding: " SUNFLOWER ", in: crops)?.key, "слънчоглед")
        XCTAssertNil(TreatmentEntryFlow.crop(holding: "MAIZE", in: crops), "a crop the farm doesn't group: pick by hand")
        XCTAssertNil(TreatmentEntryFlow.crop(holding: nil, in: crops))
        XCTAssertNil(TreatmentEntryFlow.crop(holding: "", in: crops))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @MainActor func testTheHistoryOpensTheJournalsFlowOnTheParcel() throws {
        let history = SignOutHygieneTests.code(try source("Agrent/Locations/ParcelHistoryView.swift"))
        XCTAssertTrue(history.contains("TreatmentEntryFlow(recorder: LiveTreatmentRecorder(), preselect: [recordIn.parcel.id]"))
        XCTAssertFalse(history.contains("ParcelOperationSheet("), "the old form of its own is not opened")
        let journal = SignOutHygieneTests.code(try source("Agrent/Journal/JournalListView.swift"))
        XCTAssertTrue(journal.contains("TreatmentEntryFlow(recorder: LiveTreatmentRecorder())"), "positive control")
    }

    func testEveryStepHasNazad() throws {
        for step in ["Agrent/Journal/Treatment/TreatmentPlaceView.swift", "Agrent/Journal/Treatment/TreatmentCheckView.swift"] {
            XCTAssertTrue(try source(step).contains(".stepBack("), "\(step) has no «Назад»")
        }
        let check = try source("Agrent/Journal/Treatment/TreatmentCheckView.swift")
        XCTAssertFalse(check.contains("placement: .cancellationAction"),
                       "«Отказ» is not at the top left beside «Назад»")
    }
}
