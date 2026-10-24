import XCTest
@testable import Agrent

/// Борса's one search finds farms too (owner, 2026-10-24): what was typed,
/// read as the directory's own parameters, narrowed by the map's oblasti.
final class BoardFarmsTests: XCTestCase {

    func testNothingTypedAndNoOblastAsksNothing() {
        XCTAssertTrue(BoardFarmSearch.queries(text: "", regions: []).isEmpty)
        XCTAssertTrue(BoardFarmSearch.queries(text: "   ", regions: []).isEmpty)
    }

    /// The directory's `q` matches only a farm's name, so a crop goes as
    /// `crop=`, which the server compares ignoring case.
    func testACropIsTheCropFilter() {
        XCTAssertEqual(BoardFarmSearch.read("пшеница"), .crop("Пшеница"))
        XCTAssertEqual(BoardFarmSearch.read("Пшеница"), .crop("Пшеница"))
        XCTAssertEqual(BoardFarmSearch.read("wheat"), .crop("Пшеница"))
        XCTAssertEqual(BoardFarmSearch.read("слън"), .crop("Слънчоглед"), "a unique prefix")
        let query = BoardFarmSearch.queries(text: "пшеница", regions: []).first
        XCTAssertEqual(query?.crop, "Пшеница")
        XCTAssertEqual(query?.text, "")
    }

    func testAnOblastIsTheOblastFilter() {
        XCTAssertEqual(BoardFarmSearch.read("Плевен"), .oblast("Плевен"))
        XCTAssertEqual(BoardFarmSearch.read("плев"), .oblast("Плевен"))
        XCTAssertEqual(BoardFarmSearch.queries(text: "Добрич", regions: []).first?.oblast, "Добрич")
    }

    /// Two letters, or a prefix several things share, is a name.
    func testAnythingElseIsAName() {
        XCTAssertEqual(BoardFarmSearch.read("Синтетично стопанство"), .name("Синтетично стопанство"))
        XCTAssertEqual(BoardFarmSearch.read("со"), .name("со"), "two letters start several crops")
        XCTAssertEqual(BoardFarmSearch.read("Соф"), .name("Соф"), "two oblasti start «Соф»")
        XCTAssertEqual(BoardFarmSearch.queries(text: "Тестова", regions: []).first?.text, "Тестова")
    }

    /// The map's oblasti narrow the farms as they narrow the board: one
    /// directory request per oblast, since it takes one.
    func testTheMapsOblastiNarrowTheFarms() {
        let queries = BoardFarmSearch.queries(text: "пшеница", regions: ["BG-15", "BG-08"])
        XCTAssertEqual(queries.map(\.oblast), ["Плевен", "Добрич"])
        XCTAssertTrue(queries.allSatisfy { $0.crop == "Пшеница" })
        let onlyMap = BoardFarmSearch.queries(text: "", regions: ["BG-15"])
        XCTAssertEqual(onlyMap.map(\.oblast), ["Плевен"])
        XCTAssertEqual(BoardFarmSearch.queries(text: "Добрич", regions: ["BG-15"]).first?.oblast, "Плевен",
                       "the map's choice is the board's, so it is the farms' too")
    }

    func testAFullAnswerSaysHowToNarrowIt() {
        XCTAssertNil(BoardFarmsStore.footer(count: 3))
        XCTAssertNotNil(BoardFarmsStore.footer(count: FarmDirectoryAPI.limit))
    }

    /// «Съобщения» took «Ферми»'s place on the bar, and the row under the
    /// title has three sections.
    func testTheInboxIsARouteAndTheRowHasThree() {
        XCTAssertEqual(AppRoute.exchangeInbox.home, .exchange)
        XCTAssertEqual(ExchangeView.Tab.allCases.map(\.label), ["Обяви", "Моите обяви", "Моите заявки"])
    }
}
