import XCTest
@testable import Agrent

/// «Агрономически календар» (#633): the server's dataset reads, every
/// window is cited to a source that exists, units are the closed set, and
/// the words are plain Bulgarian.
final class AgroCalendarTests: XCTestCase {

    /// The server's answer for a region, as `GET /api/agro-calendar` sends
    /// it (`Tests/Fixtures/agro-calendar-<region>.json`, the compiled МЗХ
    /// dataset in the API's shape).
    private func calendar(_ region: AgroRegion = .north) throws -> AgroCalendar {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agro-calendar-\(region.rawValue)", withExtension: "json"))
        return try JSONDecoder().decode(AgroCalendar.self, from: Data(contentsOf: url))
    }

    func testTheFieldCropsAllReadAndAreAllCited() throws {
        let calendar = try calendar()
        XCTAssertGreaterThanOrEqual(calendar.crops(in: .field).count, 8)
        XCTAssertFalse(calendar.crops(in: .vegetable).isEmpty)
        XCTAssertFalse(calendar.crops(in: .perennial).isEmpty)
        for crop in calendar.crops { XCTAssertFalse(crop.windows.isEmpty, "\(crop.key) has no windows") }
        let windows = calendar.crops.flatMap(\.windows)
        XCTAssertEqual(Set(windows.map(\.id)).count, windows.count, "ids are unique")
        for window in windows {
            for citation in window.citations {
                XCTAssertNotNil(calendar.sources[citation.source], "\(window.id) cites \(citation.source), which is not listed")
            }
        }
        let units = Set(windows.flatMap { [$0.seedRate?.unit, $0.depth?.unit].compactMap { $0 } })
        XCTAssertTrue(units.isSubset(of: Set(AgroWords.units.keys)), "unknown units: \(units.subtracting(AgroWords.units.keys))")
    }

    /// Wheat in the north is the Danube plain and Dobrudzha window, cited to
    /// page 20 of the МЗХ guide; the south's is its own.
    func testWheatSowingByRegion() throws {
        let wheat = try XCTUnwrap(try calendar().crops.first { $0.key == "wheat-bread" })
        let north = wheat.windows(.sowing, in: .north)
        XCTAssertEqual(north.map(\.from), ["09-25"])
        XCTAssertEqual(north.first?.cite.page, "20")
        let southWheat = try XCTUnwrap(try calendar(.south).crops.first { $0.key == "wheat-bread" })
        XCTAssertEqual(southWheat.windows(.sowing, in: .south).map(\.from), ["10-01"])
        XCTAssertFalse(southWheat.windows(.fieldwork, in: .south).isEmpty, "\"both\" windows apply to either region")
        XCTAssertEqual(AgroWords.amount(try XCTUnwrap(north.first?.seedRate)), "500–600 кълняеми семена на м²")
        XCTAssertEqual(AgroWords.span("09-25", "10-10"), "25 септември – 10 октомври")
    }

    /// A window across New Year is one window, not two.
    /// Pruning from mid-December to the end of March is one window.
    func testPerennialPruningWrapsTheYear() throws {
        let apple = try XCTUnwrap(try calendar().crops.first { $0.key == "apple" })
        let pruning = try XCTUnwrap(apple.windows.first { $0.id == "apple.pruning" })
        XCTAssertEqual(pruning.from, "12-15")
        XCTAssertEqual(pruning.to, "03-30")
        XCTAssertEqual(try calendar().sources[pruning.cite.source]?.publisher, "МЗХ")
    }

    func testAWindowCanWrapTheYear() {
        func day(_ month: Int, _ day: Int) -> Date {
            FarmRecordAPI.farmCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        }
        XCTAssertTrue(AgroWords.isNow("10-01", "03-31", today: day(1, 15)))
        XCTAssertTrue(AgroWords.isNow("10-01", "03-31", today: day(11, 2)))
        XCTAssertFalse(AgroWords.isNow("10-01", "03-31", today: day(6, 1)))
        XCTAssertTrue(AgroWords.isNow("09-25", "10-10", today: day(10, 1)))
    }

    func testAWindowWithoutACitationIsLeftOut() throws {
        let json = """
        {"schemaVersion":1,"sources":{"s":{"title":"T","publisher":"МЗХ","url":null,"published":"2024"}},
         "crops":[{"key":"x","group":"field","name":{"bg":"Х"},"windows":[
           {"id":"x.1","kind":"sowing","band":"optimal","region":"both","from":"09-01","to":"09-30","cite":{"source":"s","page":1}},
           {"id":"x.2","kind":"sowing","band":"optimal","region":"both","from":"10-01","to":"10-30"}
         ]}]}
        """
        let calendar = try JSONDecoder().decode(AgroCalendar.self, from: Data(json.utf8))
        XCTAssertEqual(calendar.crops.first?.windows.map(\.id), ["x.1"], "an uncited window is not served")
    }

    func testTheWordsArePlainBulgarian() throws {
        let calendar = try calendar()
        let texts = calendar.crops.flatMap { $0.windows.flatMap { [$0.note?.bg, $0.title?.bg].compactMap { $0 } } }
            + [AgroWords.notice, AgroWords.title, AgroWords.calendars]
        for text in texts {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }

    /// The API's shape (agri-saas #3094): `cites` together, a page as a
    /// number or as a span.
    func testTheAPIsCitesAreRead() throws {
        let json = """
        {"sources":{"a":{"title":"A","publisher":"МЗХ","url":"https://example.org/a.pdf"}},
         "crops":[{"key":"x","group":"field","name":{"bg":"Х"},"windows":[
           {"id":"x.1","kind":"harvest","region":"both","from":"07-01","to":"07-31",
            "cites":[{"source":"a","page":4},{"source":"a","page":"20–21"}]},
           {"id":"x.2","kind":"harvest","region":"both","from":"08-01","to":"08-31","cites":[]}]}]}
        """
        let calendar = try JSONDecoder().decode(AgroCalendar.self, from: Data(json.utf8))
        let windows = try XCTUnwrap(calendar.crops.first).windows
        XCTAssertEqual(windows.map(\.id), ["x.1"], "a window with no citation is left out")
        XCTAssertEqual(windows[0].citations.map(\.page), ["4", "20–21"])
    }

    /// Every window the compiled dataset holds reads from the API's shape:
    /// none is lost to the decoder (37 crops; 121 windows north, 122 south).
    func testNoWindowIsLostReadingTheAPI() throws {
        XCTAssertEqual(try calendar(.north).crops.count, 37)
        XCTAssertEqual(try calendar(.north).crops.flatMap(\.windows).count, 121)
        XCTAssertEqual(try calendar(.south).crops.flatMap(\.windows).count, 122)
    }

    func testThePathNamesTheRegion() {
        XCTAssertEqual(AgroCalendarAPI.path(region: .south), "/api/agro-calendar?region=south")
    }

    /// agri-saas #3100: `agroRegion` on each block, nil when the server could
    /// not tell or sends a word this build does not know; the calendar opens
    /// on a half only when every placed block agrees.
    func testTheBlocksPickTheHalfOnlyWhenTheyAgree() throws {
        func blocks(_ regions: [String]) throws -> [Location] {
            let rows = regions.enumerated().map { index, region in
                "{\"id\":\"l\(index)\",\"name\":\"Блок \(index)\",\"status\":\"ACTIVE\"\(region)}"
            }
            return try JSONDecoder().decode([Location].self, from: Data("[\(rows.joined(separator: ","))]".utf8))
        }
        let south = #","agroRegion":"south""#, north = #","agroRegion":"north""#
        let unknown = #","agroRegion":"null""#, null = #","agroRegion":null"#
        XCTAssertEqual(AgroRegion.of(try blocks([south, south, null, ""])), .south, "null and absent have no opinion")
        XCTAssertNil(AgroRegion.of(try blocks([south, north])), "both halves: no default")
        XCTAssertNil(AgroRegion.of(try blocks([null, ""])), "none placed: no default")
        XCTAssertNil(try blocks([unknown]).first?.agroRegion, "an unknown word is no region")
    }

    /// МЗХ's vineyard costs (#637, agri-saas #3127): euro per дка as the
    /// server converted them, only on the one priced card, with the owner's
    /// marker and no lev figure or rate on screen.
    func testTheVineCostsAreTheServersEuroFigures() throws {
        let calendar = try calendar()
        let priced = calendar.crops.filter { $0.costs != nil }.map(\.key)
        XCTAssertEqual(priced, ["wine-grape"], "МЗХ prices one card")
        let costs = try XCTUnwrap(calendar.crops.first { $0.key == "wine-grape" }?.costs)
        XCTAssertEqual(costs.perDaEurCentsTotal, 56801)
        XCTAssertEqual(costs.lines.compactMap(\.perDaEurCents), [2136, 16590, 30260, 2600, 5215])
        XCTAssertEqual(Set(costs.lines.map(\.key)), Set(AgroWords.costLabels.keys), "every line has words")
        XCTAssertEqual(AgroWords.perDa(56801), "568,01 EUR на дка")
        XCTAssertEqual(AgroWords.costsNote(year: "2026"), "по МЗХ (2026), превалутирано")
        XCTAssertNil(AgroWords.costsNote(year: "2026").range(of: "лв|лева|1,95583", options: .regularExpression))
    }
}
