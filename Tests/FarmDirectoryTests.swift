import XCTest
@testable import Agrent

/// The farm directory (agrent-ios #323): its query, its answer, what a row
/// says, and that Борса's search asks it only behind the flag (#419).
/// Synthetic values throughout; nothing here reaches a network.
final class FarmDirectoryTests: XCTestCase {

    // MARK: - The query

    /// An empty query browses: only the limit goes, always the server's most.
    func testBrowsingSendsOnlyTheLimit() {
        XCTAssertEqual(FarmDirectoryAPI.searchPath(FarmDirectoryQuery()), "/api/public/farms?limit=50")
        XCTAssertEqual(FarmDirectoryAPI.searchPath(FarmDirectoryQuery(text: "   ", oblast: " ", crop: "")),
                       "/api/public/farms?limit=50")
    }

    /// Each value trimmed and escaped once; Cyrillic travels as UTF-8 bytes.
    func testEachValueIsTrimmedAndEscaped() {
        let path = FarmDirectoryAPI.searchPath(
            FarmDirectoryQuery(text: " Тест & Ко ", oblast: "Стара Загора", crop: "пшеница"))
        XCTAssertEqual(path, "/api/public/farms?limit=50"
            + "&q=%D0%A2%D0%B5%D1%81%D1%82%20%26%20%D0%9A%D0%BE"
            + "&oblast=%D0%A1%D1%82%D0%B0%D1%80%D0%B0%20%D0%97%D0%B0%D0%B3%D0%BE%D1%80%D0%B0"
            + "&crop=%D0%BF%D1%88%D0%B5%D0%BD%D0%B8%D1%86%D0%B0")
    }

    /// Over the server's bounds it answers 400, so a long value is cut.
    func testALongValueIsCutToTheServersBound() throws {
        let path = FarmDirectoryAPI.searchPath(FarmDirectoryQuery(text: String(repeating: "a", count: 130),
                                                                  crop: String(repeating: "b", count: 90)))
        let items = try XCTUnwrap(URLComponents(string: path)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value?.count, FarmDirectoryQuery.maxText)
        XCTAssertEqual(items.first { $0.name == "crop" }?.value?.count, FarmDirectoryQuery.maxFilter)
    }

    func testOnlyOblastAndCropCountAsFilters() {
        XCTAssertFalse(FarmDirectoryQuery(text: "Тест").isFiltered)
        XCTAssertTrue(FarmDirectoryQuery(oblast: "Русе").isFiltered)
        XCTAssertTrue(FarmDirectoryQuery(crop: "ечемик").isFiltered)
    }

    // MARK: - The answer

    func testAHitReadsEveryField() throws {
        let body = #"""
        [{"handle":"test-farm","displayName":"Тестово стопанство","tagline":"Кратко",
          "oblast":"Добрич","crops":["пшеница","слънчоглед"],"score":0.42}]
        """#
        let hits = try FarmDirectoryAPI.decodeHits(from: Data(body.utf8))
        XCTAssertEqual(hits, [FarmDirectoryHit(handle: "test-farm", displayName: "Тестово стопанство",
                                               tagline: "Кратко", oblast: "Добрич",
                                               crops: ["пшеница", "слънчоглед"])])
        XCTAssertEqual(hits.first?.id, "test-farm")
    }

    /// A row with no handle or no name can be neither opened nor named, so it
    /// goes; the rest stay. Blank text reads as absent.
    func testABrokenRowCostsOnlyItself() throws {
        let body = #"""
        [{"displayName":"Без адрес"},
         {"handle":"no-name"},
         {"handle":"kept","displayName":"Запазено","tagline":"  ","oblast":null,"crops":["", " ечемик "]},
         {"handle":"odd","displayName":"Странно","crops":"пшеница","tagline":7}]
        """#
        let hits = try FarmDirectoryAPI.decodeHits(from: Data(body.utf8))
        XCTAssertEqual(hits.map(\.handle), ["kept", "odd"])
        XCTAssertNil(hits[0].tagline)
        XCTAssertNil(hits[0].oblast)
        XCTAssertEqual(hits[0].crops, ["ечемик"])
        XCTAssertEqual(hits[1].crops, [])
        XCTAssertNil(hits[1].tagline)
    }

    /// Not an array: an error, never an empty directory.
    func testAnAnswerThatIsntAListFails() {
        XCTAssertThrowsError(try FarmDirectoryAPI.decodeHits(from: Data(#"{"farms":[]}"#.utf8)))
        XCTAssertNoThrow(try FarmDirectoryAPI.decodeHits(from: Data("[]".utf8)))
    }

    // MARK: - The row and the screen

    func testARowSaysWhatItPrints() {
        let hit = FarmDirectoryHit(handle: "test-farm", displayName: "Тестово стопанство",
                                   tagline: "Зърно от Добруджа", oblast: "Добрич",
                                   crops: ["пшеница", "слънчоглед"])
        XCTAssertEqual(FarmDirectoryRow.spoken(hit),
                       "Тестово стопанство, Зърно от Добруджа, област Добрич, отглежда пшеница, слънчоглед.")
        XCTAssertEqual(FarmDirectoryRow.spoken(FarmDirectoryHit(handle: "x", displayName: "Само име")),
                       "Само име.")
    }

    /// A farm opens as its web page, and only a web address opens: Safari's
    /// view raises on any other scheme.
    func testOnlyAWebPageOpens() throws {
        let page = try XCTUnwrap(PublicProfileLink.url(handle: "test-farm"))
        XCTAssertTrue(InAppBrowser.opens(page))
        XCTAssertTrue(page.path().hasSuffix("/f/test-farm"))
        XCTAssertFalse(InAppBrowser.opens(try XCTUnwrap(URL(string: "mailto:test"))))
        XCTAssertFalse(InAppBrowser.opens(try XCTUnwrap(URL(string: "agrent://f/test-farm"))))
    }

    /// The board's farm search runs behind the flag every P6 route answers
    /// 404 on, as the editor is (#323): with it off, Борса shows no farms.
    func testTheFarmSearchIsBehindTheFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let exchange = try String(contentsOf: root.appendingPathComponent("Agrent/Exchange/ExchangeView.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(exchange.contains("struct ExchangeView"), "positive control")
        let gate = try XCTUnwrap(exchange.range(of: "flags.isOn(FarmBrandAPI.flag) else { farms.clear(); return }"))
        let load = try XCTUnwrap(exchange.range(of: "await farms.load("))
        XCTAssertLessThan(gate.lowerBound, load.lowerBound)
        XCTAssertEqual(exchange.components(separatedBy: "await farms.load(").count, 2, "searched from one place")
        XCTAssertFalse(exchange.contains("AppRoute.farmDirectory"), "the «Ферми» screen is gone")
    }
}
