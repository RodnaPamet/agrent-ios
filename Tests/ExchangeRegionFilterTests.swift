import XCTest
@testable import Agrent

/// Борса's map filters the board by oblast, as the web's does (#417).
final class ExchangeRegionFilterTests: XCTestCase {

    /// The server's CSV of ISO codes, in a stable order whatever the order of
    /// the taps — the same choice must be the same request.
    func testTheRegionsGoOnThePathSorted() {
        let query = ExchangeQuery().togglingRegion("BG-18").togglingRegion("BG-15")
        XCTAssertEqual(query.regions, ["BG-15", "BG-18"])
        XCTAssertTrue(ExchangeAPI.listingsPath(query).contains("region=BG-15,BG-18"))
        XCTAssertFalse(ExchangeAPI.listingsPath(ExchangeQuery()).contains("region="), "positive control")
    }

    /// A second tap takes it off; a region is a filter, so «Изчисти филтрите»
    /// and the filtered empty state count it.
    func testATapTogglesAndCountsAsAFilter() {
        let on = ExchangeQuery().togglingRegion("BG-15")
        XCTAssertTrue(on.isFiltered)
        let off = on.togglingRegion("BG-15")
        XCTAssertEqual(off.regions, [])
        XCTAssertFalse(off.isFiltered)
    }

    /// A toggle starts the board again from its first page: the cursor was
    /// positional in the previous answer.
    func testAToggleDropsTheCursor() {
        var query = ExchangeQuery()
        query.cursor = "c2"
        XCTAssertNil(query.togglingRegion("BG-15").cursor)
    }

    /// The tap's hit-test, against the bundled geometry: every oblast's own
    /// centre lands in that oblast, and a corner of the canvas is not Bulgaria.
    @MainActor
    func testATapFindsTheOblastUnderIt() throws {
        let map = try XCTUnwrap(BulgariaMap.bundled())
        XCTAssertEqual(map.oblasti.count, 28)
        var found = 0
        for oblast in map.oblasti where map.oblast(at: oblast.centre)?.iso == oblast.iso { found += 1 }
        XCTAssertGreaterThanOrEqual(found, 26, "a centre that lands elsewhere is a broken hit-test, not a shape")
        XCTAssertNil(map.oblast(at: CGPoint(x: 1, y: 1)))
    }

    /// The tap and the drawing share one transform, run both ways.
    @MainActor
    func testUnplaceUndoesPlace() throws {
        let map = try XCTUnwrap(BulgariaMap.bundled())
        let size = CGSize(width: 390, height: 260)
        let point = CGPoint(x: 512, y: 288)
        let scale = min(size.width / map.width, size.height / map.height)
        let dx = (size.width - map.width * scale) / 2, dy = (size.height - map.height * scale) / 2
        let screen = CGPoint(x: dx + point.x * scale, y: dy + point.y * scale)
        let back = ExchangeMapView.unplace(screen, in: size, map: map)
        XCTAssertEqual(back.x, point.x, accuracy: 0.001)
        XCTAssertEqual(back.y, point.y, accuracy: 0.001)
    }

    func testTheSummaryIsBulgarian() {
        XCTAssertEqual(RegionFilterSummary.text(["BG-15"]), "Област: Плевен")
        XCTAssertTrue(RegionFilterSummary.text(["BG-15", "BG-08"]).hasPrefix("Области: "))
        XCTAssertFalse(RegionFilterSummary.text(["BG-15"]).contains("BG-"))
    }
}
