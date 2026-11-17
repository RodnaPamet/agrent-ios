import XCTest
@testable import Agrent

/// Pest and disease thresholds (#636): the server's answer reads, a crop
/// finds its own, and «Риск» takes the crop from this year's РЕКОЛТИ record.
final class AgroThresholdsTests: XCTestCase {

    /// `GET /api/agro-thresholds` as the server sends it
    /// (`Tests/Fixtures/agro-thresholds.json`, dumped from agri-saas#3157).
    private func thresholds() throws -> AgroThresholds {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agro-thresholds", withExtension: "json"))
        return try JSONDecoder().decode(AgroThresholds.self, from: Data(contentsOf: url))
    }

    private func seasons(_ json: String) throws -> [CropSeason] {
        try JSONDecoder().decode([CropSeason].self, from: Data(json.utf8))
    }

    private func day(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testTheServersAnswerReads() throws {
        let all = try thresholds().thresholds
        XCTAssertEqual(all.count, 29)
        for t in all { XCTAssertFalse(t.levels.isEmpty, t.id) }
    }

    func testACropGetsItsOwnPestsFirst() throws {
        let wheat = try thresholds().for("wheat")
        XCTAssertFalse(wheat.isEmpty)
        XCTAssertTrue(wheat.allSatisfy { $0.crops.contains("wheat") })
        XCTAssertTrue(wheat.map(\.id).contains("powdery-mildew"))
        let firstDisease = try XCTUnwrap(wheat.firstIndex { $0.kind == .disease })
        XCTAssertTrue(wheat[firstDisease...].allSatisfy { $0.kind == .disease }, "pests, then diseases")
        // Control: the guide covers no rapeseed, and nil joins nothing.
        XCTAssertTrue(try thresholds().for("rapeseed").isEmpty)
        XCTAssertTrue(try thresholds().for(nil).isEmpty)
    }

    func testAnEntryWithoutAReadableLevelIsLeftOut() throws {
        let json = #"""
        {"thresholds":[
          {"id":"a","kind":"pest","name":{"bg":"А"},"crops":["wheat"],"levels":[]},
          {"id":"b","kind":"pest","name":{"bg":"Б"},"crops":["wheat"],"levels":[{"stage":{"bg":"есен"},"threshold":{"bg":"5 бр./м²"}}]},
          {"id":"c","kind":"weather","name":{"bg":"В"},"crops":["wheat"],"levels":[{"stage":{"bg":"x"},"threshold":{"bg":"y"}}]}
        ]}
        """#
        let read = try JSONDecoder().decode(AgroThresholds.self, from: Data(json.utf8))
        XCTAssertEqual(read.thresholds.map(\.id), ["b"])
    }

    func testAParcelsFreeTextCropFindsItsSlug() {
        XCTAssertEqual(CommodityName.slug(freeText: "Canola"), "rapeseed")
        XCTAssertEqual(CommodityName.slug(freeText: "Wheat"), "wheat")
        XCTAssertEqual(CommodityName.slug(freeText: " MAIZE "), "maize")
        XCTAssertEqual(CommodityName.slug(freeText: "Пшеница"), "wheat")
        XCTAssertEqual(CommodityName.slug(freeText: "Рапица"), "rapeseed")
        // The farm's own word joins nothing — never a guess.
        XCTAssertNil(CommodityName.slug(freeText: "Люцерна"))
        XCTAssertNil(CommodityName.slug(freeText: "Grass ley"))
        XCTAssertNil(CommodityName.slug(freeText: "  "))
    }

    func testRiskTakesThisYearsCropFromTheRecord() throws {
        let list = try seasons(#"""
        [{"id":"s1","year":2026,"cropType":"Wheat","sownAt":"2025-10-20T00:00:00.000Z"},
         {"id":"s2","year":2025,"cropType":"Sunflower"}]
        """#)
        let crop = try XCTUnwrap(AgroThresholds.thisYearsCrop(list, now: try day("2026-06-01T09:00:00Z")))
        XCTAssertEqual(crop.slug, "wheat")
        XCTAssertEqual(crop.label, "Пшеница")
        XCTAssertEqual(ThresholdWords.riskRow(crop.label), "Прагове за вредители: Пшеница")
        // No record for this year: nothing, not last year's crop.
        XCTAssertNil(AgroThresholds.thisYearsCrop(list, now: try day("2027-03-01T09:00:00Z")))
    }

    func testTheYearIsTheFarmsNotTheDevicesAndTheLaterSowingWins() throws {
        let list = try seasons(#"""
        [{"id":"s1","year":2027,"cropType":"Barley","sownAt":"2026-10-01T00:00:00.000Z"},
         {"id":"s2","year":2027,"cropType":"Maize","sownAt":"2027-05-01T00:00:00.000Z"},
         {"id":"s3","year":2026,"cropType":"Люцерна"}]
        """#)
        // 23:30 UTC on 31 December is already 1 January in Sofia.
        let crop = AgroThresholds.thisYearsCrop(list, now: try day("2026-12-31T23:30:00Z"))
        XCTAssertEqual(crop?.slug, "maize")
        // A crop of the farm's own wording joins nothing.
        XCTAssertNil(AgroThresholds.thisYearsCrop(list, now: try day("2026-06-01T09:00:00Z")))
    }

    func testThePathAndThePlainWords() {
        XCTAssertEqual(AgroThresholdsAPI.path, "/api/agro-thresholds")
        for word in [ThresholdWords.title, ThresholdWords.note, ThresholdWords.pest, ThresholdWords.disease] {
            XCTAssertNil(word.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), word)
        }
    }
}
