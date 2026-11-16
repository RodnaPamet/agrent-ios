import XCTest
@testable import Agrent

/// «Агрономически календар» (#633): the bundled dataset reads, every
/// window is cited to a source that exists, units are the closed set, and
/// the words are plain Bulgarian.
final class AgroCalendarTests: XCTestCase {

    private func calendar() throws -> AgroCalendar {
        try XCTUnwrap(AgroCalendar.bundled(), "the bundled agro-calendar.json must read")
    }

    func testTheBundledFieldCropsAllReadAndAreAllCited() throws {
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
        XCTAssertEqual(north.first?.cite.page, 20)
        XCTAssertEqual(wheat.windows(.sowing, in: .south).map(\.from), ["10-01"])
        XCTAssertFalse(wheat.windows(.fieldwork, in: .south).isEmpty, "\"both\" windows apply to either region")
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
}
