import XCTest
@testable import Agrent

/// «Календар: поправки» (agri-saas#3095): the console's wire shapes and words.
final class CalendarOverridesTests: XCTestCase {
    func testTheListReads() throws {
        let json = #"""
        {"overrides":[{"windowId":"potato.agrent.1a2b3c4d","cropKey":"potato","origin":"added",
          "window":{"id":"potato.agrent.1a2b3c4d","kind":"sowing","band":"optimal","region":"both","from":"03-15","to":"04-15"},
          "basis":{"bg":"НССЗ, март"},"authorRef":"user:u1","setAt":"2026-11-17T21:00:00.000Z"}]}
        """#
        struct List: Decodable { let overrides: [CalendarOverridesAPI.Override] }
        let row = try XCTUnwrap(try JSONDecoder().decode(List.self, from: Data(json.utf8)).overrides.first)
        XCTAssertTrue(row.isAddition)
        XCTAssertEqual(row.window.band, "optimal")
        XCTAssertEqual(row.basis.bg, "НССЗ, март")
    }

    /// The body never carries a citation, and a window with no band says so by
    /// leaving the key out.
    func testTheWindowIsSentWithoutACitationOrAnEmptyBand() throws {
        let draft = CalendarOverridesAPI.WindowDraft(id: "wheat-bread.agrent.x", kind: "harvest", band: nil,
                                                     region: "north", from: "07-01", to: "07-31", title: nil)
        let text = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        XCTAssertFalse(text.contains("cite"))
        XCTAssertFalse(text.contains("band"))
        XCTAssertTrue(text.contains(#""from":"07-01""#))
    }

    func testANewIdIsNeverOneOfMZHsAndNamesTheCrop() {
        let id = CalendarOverridesText.newID(crop: "potato-mid-early")
        XCTAssertTrue(id.hasPrefix("potato-mid-early.agrent."))
        XCTAssertNotEqual(id, CalendarOverridesText.newID(crop: "potato-mid-early"))
    }

    func testTheWords() {
        XCTAssertEqual(CalendarOverridesText.kind("sowing", band: "early"), "Ранна сеитба")
        XCTAssertEqual(CalendarOverridesText.kind("harvest", band: nil), "Прибиране")
        XCTAssertEqual(CalendarOverridesText.region("both"), "Цялата страна")
        XCTAssertEqual(CalendarOverridesText.region("south"), "Южна България")
        XCTAssertEqual(BgDate.monthName(3), "март")
        XCTAssertEqual(BgDate.monthName(13), "13")
    }

    func testTheConsoleAddressesThePlatformFarmsAdminRoutes() {
        XCTAssertTrue(CalendarOverridesAPI.listPath.hasSuffix("/admin/agro-calendar/overrides"))
        XCTAssertTrue(CalendarOverridesAPI.windowPath("a.b c").hasSuffix("/admin/agro-calendar/overrides/a.b%20c"))
    }
}
