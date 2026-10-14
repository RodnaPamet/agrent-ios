import XCTest
@testable import Agrent

/// The ДНЕВНИК list's folded rows (agri-saas #1799): one row per treatment,
/// still entry-shaped, with the treatment in an added `treatment` object.
/// Synthetic names throughout — this repo is public.
@MainActor
final class JournalFoldTests: XCTestCase {
    /// A page as `listJournalEntries` answers it with `limit`: a treatment
    /// over three parcels in two blocks, a free-hand entry folded to itself,
    /// a row from a server that predates the fold, and two rows whose
    /// `treatment` is not what the spec says.
    private let page = Data("""
    {
      "rows": [
        {"id": "le_1", "type": "INPUT_APPLICATION", "status": "DONE",
         "title": "Тестов препарат — Парцел 7", "occurredAt": "2026-10-12T00:00:00.000Z",
         "treatment": {"treatmentGroupId": "tg_1", "occurredOn": "2026-10-12", "kind": "SPRAY",
                       "productName": "Тестов препарат", "parcelCount": 3, "totalAreaHa": 4.25,
                       "blockNames": ["Блок А", "Блок Б"], "doseValue": 1.5, "doseUnit": "л/дка",
                       "quarantinePeriodDays": 14, "earliestHarvestOn": "2026-10-26"}},
        {"id": "le_2", "type": "OBSERVATION", "status": "DONE",
         "title": "Оглед на посева", "occurredAt": "2026-10-11T08:30:00.000Z",
         "treatment": {"treatmentGroupId": "le_2", "occurredOn": "2026-10-11",
                       "productName": null, "parcelCount": 0, "totalAreaHa": 0, "blockNames": []}},
        {"id": "le_3", "type": "OBSERVATION", "status": "DONE",
         "title": "Без сгъване", "occurredAt": "2026-10-10T08:30:00.000Z"},
        {"id": "le_4", "type": "OBSERVATION", "status": "DONE",
         "title": "Странно", "occurredAt": "2026-10-09T08:30:00.000Z", "treatment": "не е обект"},
        {"id": "le_5", "type": "INPUT_APPLICATION", "status": "DONE",
         "title": "Друг препарат — Парцел 2", "occurredAt": "2026-10-08T00:00:00.000Z",
         "treatment": {"parcelCount": "много", "productName": 7, "blockNames": "Блок В"}}
      ],
      "nextCursor": null
    }
    """.utf8)

    /// Every row decodes — one odd `treatment` must not empty the launch
    /// screen — and the treatment's facts arrive.
    func testAFoldedPageDecodesWholeAndOddRowsReadAsPlainEntries() async throws {
        let slice = try await JournalAPI.decodeList(from: page)
        XCTAssertEqual(slice.entries.map(\.id), ["le_1", "le_2", "le_3", "le_4", "le_5"])

        let treatment = try XCTUnwrap(slice.entries[0].treatment)
        XCTAssertTrue(treatment.isTreatment)
        XCTAssertEqual(treatment.parcelCount, 3)
        XCTAssertEqual(treatment.area?.text, Area(hectares: 4.25).text)
        XCTAssertEqual(treatment.blockNames, ["Блок А", "Блок Б"])
        XCTAssertEqual(treatment.earliestHarvest.map(BgDate.isoDay), "2026-10-26")

        XCTAssertEqual(slice.entries[1].treatment?.isTreatment, false, "a free-hand entry folds to itself")
        XCTAssertNil(slice.entries[2].treatment, "a server before the fold sends none")
        XCTAssertFalse(slice.entries[3].treatment?.isTreatment ?? false)
        XCTAssertEqual(slice.entries[4].treatment?.parcelCount, 0, "a count that is not a number is no count")
        XCTAssertEqual(slice.entries[4].treatment?.blockNames, [])
    }

    /// A treatment is titled by its product: the entry's own title names ONE
    /// parcel of the three. Everything else keeps its own title.
    func testATreatmentIsTitledByItsProductNotOneParcel() async throws {
        let rows = try await JournalAPI.decodeList(from: page).entries
        XCTAssertEqual(rows[0].displayTitle, "Тестов препарат")
        XCTAssertEqual(rows[1].displayTitle, "Оглед на посева")
        XCTAssertEqual(rows[2].displayTitle, "Без сгъване")
        XCTAssertEqual(rows[4].displayTitle, "Друг препарат — Парцел 2",
                       "a row whose treatment cannot be read keeps the title it has")
    }

    /// Spoken in words — «декара», not the «дка» VoiceOver spells out — and
    /// nothing at all for a row that is no treatment.
    func testTheTreatmentIsSpokenInWords() async throws {
        let rows = try await JournalAPI.decodeList(from: page).entries
        let spoken = JournalRow.spokenTreatment(rows[0].treatment).compactMap { $0 }
        XCTAssertEqual(spoken.first, "3 парцела")
        XCTAssertTrue(spoken.contains(Area(hectares: 4.25).spoken))
        XCTAssertTrue(spoken.contains("Блок А, Блок Б"))
        XCTAssertTrue(spoken.contains { $0.hasPrefix(JournalRow.harvestLabel) })
        XCTAssertFalse(spoken.contains { $0.contains("дка") }, "an abbreviation reached the spoken label")

        XCTAssertEqual(JournalRow.spokenTreatment(rows[1].treatment).count, 0)
        XCTAssertEqual(JournalRow.spokenTreatment(nil).count, 0)
    }
}
