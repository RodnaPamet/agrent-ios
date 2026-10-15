import XCTest
@testable import Agrent

/// «Ферми» (agrent-ios #323): the directory's query, its answer, the crop
/// filter's choices, what a row says, and where the screen is offered.
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

    // MARK: - The crop filter's choices

    /// Bulgarian order whatever the phone's language, and case kept: the
    /// server matches a crop exactly, so «Пшеница» and «пшеница» are two
    /// choices that find different farms.
    func testCropsAreInBulgarianOrderWithTheirCaseKept() {
        XCTAssertEqual(FarmDirectoryStore.sorted(["ябълки", "ечемик", "царевица", "люцерна"]),
                       ["ечемик", "люцерна", "царевица", "ябълки"])
        XCTAssertEqual(FarmDirectoryStore.sorted(["ябълки", "Ечемик"]), ["Ечемик", "ябълки"],
                       "case doesn't move a crop")
        XCTAssertEqual(Set(FarmDirectoryStore.sorted(["Пшеница", "пшеница"])), ["Пшеница", "пшеница"])
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

    /// The server stops at 50 with no next page: a full answer says how to
    /// reach the rest.
    func testAFullAnswerSaysHowToNarrowIt() {
        XCTAssertTrue(FarmDirectoryView.footer(count: FarmDirectoryAPI.limit).contains("Стеснете"))
        XCTAssertFalse(FarmDirectoryView.footer(count: 3).contains("Стеснете"))
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

    func testTheDirectoryBelongsToTheExchange() {
        XCTAssertEqual(AppRoute.farmDirectory.home, .exchange)
        XCTAssertEqual(AppRoute.farmDirectory, AppRoute.farmDirectory)
    }

    /// Behind the flag every P6 route answers 404 on, as the editor is.
    func testTheButtonIsBehindTheFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let exchange = try String(contentsOf: root.appendingPathComponent("Agrent/Exchange/ExchangeView.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(exchange.contains("struct ExchangeView"), "positive control")
        let gate = try XCTUnwrap(exchange.range(of: "if flags.isOn(FarmBrandAPI.flag) {"))
        let link = try XCTUnwrap(exchange.range(of: "NavigationLink(value: AppRoute.farmDirectory)"))
        XCTAssertLessThan(gate.lowerBound, link.lowerBound)
        XCTAssertEqual(exchange.components(separatedBy: "AppRoute.farmDirectory").count, 2,
                       "offered once, behind the gate")
    }
}
