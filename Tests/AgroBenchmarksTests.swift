import XCTest
@testable import Agrent

/// National yields and support rates (#638): the server's answer reads, a
/// crop finds its figures by its canonical commodity, and only euro the
/// server converted is shown.
final class AgroBenchmarksTests: XCTestCase {

    /// `GET /api/agro-benchmarks` as the server sends it
    /// (`Tests/Fixtures/agro-benchmarks.json`, dumped from agri-saas#3157).
    private func figures() throws -> AgroBenchmarks {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agro-benchmarks", withExtension: "json"))
        return try JSONDecoder().decode(AgroBenchmarks.self, from: Data(contentsOf: url))
    }

    func testTheServersAnswerReads() throws {
        let figures = try figures()
        XCTAssertEqual(figures.yields.count, 13)
        XCTAssertEqual(figures.supportRates.count, 10)
        XCTAssertEqual(figures.shownRates.count, 10, "every rate carries the server's euro figure")
        XCTAssertEqual(figures.campaign, 2024)
    }

    func testAYieldIsShownPerDecareAsTheHectareFigureOverTen() throws {
        let wheat = try XCTUnwrap(try figures().yield(for: "wheat"))
        XCTAssertEqual(wheat.kgPerHa, 5731)
        XCTAssertEqual(BenchmarkWords.yieldValue(wheat), "573,1 кг/дка")
        XCTAssertEqual(BenchmarkWords.yieldLabel(wheat), "Среден добив за страната (2024)")
    }

    func testRapeseedIsFoundByItsCanonicalSlug() throws {
        // The calculator and the calendar join on `rapeseed`; the first
        // compile wrote `canola`, which nothing would have found.
        XCTAssertNotNil(try figures().yield(for: "rapeseed"))
        XCTAssertNil(try figures().yield(for: "canola"))
    }

    func testProteinCropsEarnTheProteinRateInEuro() throws {
        let figures = try figures()
        for crop in ["peas", "lentils", "soybean"] {
            XCTAssertEqual(figures.rates(for: crop).map(\.scheme), ["protein"], crop)
        }
        let protein = try XCTUnwrap(figures.rates(for: "peas").first)
        XCTAssertEqual(protein.perDaEurCents, 1302)
        XCTAssertEqual(BenchmarkWords.perDa(1302), "13,02 EUR на дка")
        // Control: a crop with no coupled scheme has none.
        XCTAssertTrue(figures.rates(for: "wheat").isEmpty)
        XCTAssertTrue(figures.rates(for: nil).isEmpty)
    }

    func testTheOverThirtyHectareRateIsSaidInDecares() throws {
        let fruit = try XCTUnwrap(try figures().shownRates.first { $0.scheme == "fruit" })
        XCTAssertEqual(fruit.perDaEurCents, 9388)
        XCTAssertEqual(BenchmarkWords.over300(try XCTUnwrap(fruit.perDaOver30EurCents)), "Над 300 дка: 62,59 EUR на дка")
    }

    func testARateWithoutTheServersEuroIsNotShown() throws {
        // EUR only: the lev figure is never on screen, so a rate the server
        // did not convert is left out rather than shown in leva.
        let json = #"""
        {"supportRates":[
          {"scheme":"a","label":{"bg":"А"},"campaign":2024,"perDaEurCents":null,"commodities":["peas"]},
          {"scheme":"b","label":{"bg":"Б"},"campaign":2024,"perDaEurCents":500,"commodities":["peas"]},
          {"scheme":"broken"}
        ],"yields":[{"commodity":"wheat","harvest":2024,"kgPerHa":"много"}]}
        """#
        let figures = try JSONDecoder().decode(AgroBenchmarks.self, from: Data(json.utf8))
        XCTAssertEqual(figures.supportRates.map(\.scheme), ["a", "b"], "an entry that does not read is left out")
        XCTAssertEqual(figures.rates(for: "peas").map(\.scheme), ["b"])
        XCTAssertTrue(figures.yields.isEmpty)
    }

    func testTheCalendarCropCarriesItsCommodity() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agro-calendar-north", withExtension: "json"))
        let calendar = try JSONDecoder().decode(AgroCalendar.self, from: Data(contentsOf: url))
        let joined = Set(calendar.crops.compactMap(\.commodityCanonical))
        XCTAssertTrue(joined.isSuperset(of: ["wheat", "rapeseed", "sunflower"]), "\(joined)")
        // Every crop the calendar joins finds a national yield.
        let figures = try figures()
        for commodity in joined { XCTAssertNotNil(figures.yield(for: commodity), commodity) }
    }

    func testThePathAndThePlainWords() {
        XCTAssertEqual(AgroBenchmarksAPI.path, "/api/agro-benchmarks")
        let words = [BenchmarkWords.supportTitle, BenchmarkWords.supportIntro, BenchmarkWords.nationalTitle]
        for word in words {
            XCTAssertNil(word.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), word)
        }
    }
}
