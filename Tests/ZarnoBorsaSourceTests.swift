import XCTest
@testable import Agrent

/// ZarnoBorsa.com prices (#627, owner 2026-11-15): a typed price still wins,
/// then ZarnoBorsa's Bulgarian EXW, ahead of the EC national average; named
/// as the source, with a link, as its terms ask.
final class ZarnoBorsaSourceTests: XCTestCase {

    private func series(_ source: String, region: String = "BG", stage: String?, unit: String = "EUR/t",
                        lastObserved: String, sourceUrl: String? = nil) throws -> PriceSeries {
        let url = sourceUrl.map { ",\"sourceUrl\":\"\($0)\"" } ?? ""
        let json = """
        {"source":"\(source)","region":"\(region)","stage":\(stage.map { "\"\($0)\"" } ?? "null"),
         "unit":"\(unit)","currency":"EUR","label":null,"lastObservedAt":"\(lastObserved)",
         "points":[{"date":"\(lastObserved)","price":188.65}]\(url)}
        """
        return try JSONDecoder().decode(PriceSeries.self, from: Data(json.utf8))
    }

    func testZarnoBorsaLeadsUnlessAPriceIsTyped() throws {
        let ec = try series("ec-agrifood", stage: "National Average - Not Specified", lastObserved: "2026-11-14")
        let exw = try series("zarnoborsa", stage: "EXW", lastObserved: "2026-11-13")
        let fob = try series("zarnoborsa", stage: "FOB", lastObserved: "2026-11-14")
        let typed = try series("platform", stage: nil, lastObserved: "2026-11-01")
        XCTAssertEqual([ec, fob, exw].lead()?.id, exw.id, "EXW Bulgaria over a fresher EC average and FOB")
        XCTAssertEqual([ec, exw, typed].lead()?.id, typed.id, "a typed price still wins")
        XCTAssertEqual([ec, fob].lead()?.id, ec.id, "FOB alone does not displace the national average")
        let romania = try series("zarnoborsa", region: "RO", stage: "EXW", lastObserved: "2026-11-14")
        XCTAssertEqual([ec, romania].lead()?.id, ec.id, "only Bulgaria's EXW leads")
    }

    func testItIsNamedAndLinked() throws {
        let exw = try series("zarnoborsa", stage: "EXW", lastObserved: "2026-11-14")
        XCTAssertEqual(SeriesSource.parts(of: exw), ["ZarnoBorsa.com", SeriesVocabulary.region("BG"), "EXW"])
        XCTAssertEqual(exw.attributionURL?.absoluteString, "https://zarnoborsa.com", "the home page when no link is sent")
        let linked = try series("zarnoborsa", stage: "FOB", lastObserved: "2026-11-14",
                                sourceUrl: "https://zarnoborsa.com/markets/fob")
        XCTAssertEqual(linked.attributionURL?.absoluteString, "https://zarnoborsa.com/markets/fob")
        let ec = try series("ec-agrifood", stage: nil, lastObserved: "2026-11-14")
        XCTAssertNil(ec.attributionURL, "positive control: the feeds carry no link")
        XCTAssertEqual(SeriesSource.zarnoborsaLink, "Източник: ZarnoBorsa.com")
    }

    /// FOB is one line under an EXW headline, and only there (owner,
    /// 2026-11-16: «Second price line»).
    func testFOBIsOneLineUnderTheEXWHeadlineOnly() throws {
        let exw = try series("zarnoborsa", stage: "EXW", lastObserved: "2026-11-14")
        let fob = try series("zarnoborsa", stage: "FOB", lastObserved: "2026-11-13")
        let ec = try series("ec-agrifood", stage: "National average", lastObserved: "2026-10-19")
        let typed = try series("platform", stage: nil, lastObserved: "2026-11-15")
        XCTAssertEqual([ec, fob, exw].fobBeside([ec, fob, exw].lead())?.id, fob.id)
        XCTAssertNil([ec, fob].fobBeside([ec, fob].lead()), "no FOB line under the EC average")
        XCTAssertNil([typed, exw, fob].fobBeside([typed, exw, fob].lead()), "nor under a typed price")
        let point = try XCTUnwrap(fob.points.first)
        let words = TrendsWords.fob(fob, point)
        XCTAssertEqual(words.shown, "FOB България: 188,65 €/т · 13 ноември")
        XCTAssertFalse(words.spoken.contains("·"))
    }

    /// МЗХ's weekly purchase price (agrent-ios#635, agri-saas#3137): after a
    /// typed price and ZarnoBorsa's EXW, ahead of the EC average; named
    /// «МЗХ / САПИ», «евро на тон» from the bare `t` unit.
    func testMZHPurchasePriceLeadsAfterZarnoBorsa() throws {
        let mzh = try series("mzh", stage: "PURCHASE", unit: "t", lastObserved: "2026-09-30")
        let exw = try series("zarnoborsa", stage: "EXW", lastObserved: "2026-11-14")
        let ec = try series("ec-agrifood", stage: "National average", lastObserved: "2026-11-10")
        let typed = try series("platform", stage: nil, lastObserved: "2026-11-15")
        XCTAssertEqual([ec, mzh].lead()?.id, mzh.id, "МЗХ over a fresher EC average")
        XCTAssertEqual([ec, mzh, exw].lead()?.id, exw.id, "ZarnoBorsa EXW still first")
        XCTAssertEqual([ec, mzh, typed].lead()?.id, typed.id, "a typed price still wins")
        XCTAssertEqual(SeriesSource.parts(of: mzh), ["МЗХ / САПИ", "Средна изкупна цена"])
        XCTAssertEqual(SeriesSource.attribution(of: mzh), "Източник: МЗХ / САПИ")
        XCTAssertNil(mzh.attributionURL, "no link unless the server sends one")
        XCTAssertNil(SeriesSource.attribution(of: ec), "positive control: the feeds carry none")
        XCTAssertEqual(SeriesVocabulary.priceUnit(unit: mzh.unit, currency: mzh.currency), "евро на тон")
        XCTAssertNil([ec, mzh].fobBeside(mzh), "no FOB line under МЗХ")
    }
}
