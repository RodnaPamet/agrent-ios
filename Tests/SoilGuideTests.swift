import XCTest
@testable import Agrent

/// «Почва» (owner, 2026-11-26): the soil guide reads as the server sends it,
/// every topic names its documents, and an assistant answer drawn from the
/// guide offers a way into it on the phone.
final class SoilGuideTests: XCTestCase {

    /// `GET /api/t/{farm}/knowledge/soil-guide?lang=bg` as the server sends it
    /// (`Tests/Fixtures/soil-guide.json`, dumped from the server's module).
    private func guide() throws -> SoilGuide {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "soil-guide", withExtension: "json"))
        return try JSONDecoder().decode(SoilGuide.self, from: Data(contentsOf: url))
    }

    func testTheServersAnswerReadsWithEveryTopicSourced() throws {
        let guide = try guide()
        XCTAssertEqual(guide.sections.map(\.id),
                       ["nitrogen", "slopes-water", "manure", "analysis", "erosion-cover", "organic-matter", "soil-life"])
        for section in guide.sections {
            XCTAssertFalse(section.points.isEmpty, section.id)
            XCTAssertFalse(section.sources.isEmpty, "\(section.id) names no document")
            for source in section.sources {
                XCTAssertNotNil(source.link, "\(source.id) has no address Safari opens")
            }
        }
        let nitrogen = try XCTUnwrap(guide.sections.first)
        XCTAssertEqual(nitrogen.title, "Азотни торове: кога и колко")
        XCTAssertTrue(nitrogen.points.contains { $0.contains("17 кг азот на декар") })
    }

    /// A topic or source the server adds later is shown, not a decode failure.
    func testAnUnknownTopicAndAnExtraFieldStillRead() throws {
        let json = #"""
        {"sections":[{"id":"something-new","title":"Ново","summary":"Кратко.","points":["Точка."],
          "sources":[{"id":"later","title":"Документ","publisher":"МЗХ","year":2027,"url":"https://example.org/x","kind":"official","extra":1}]}],
         "updated":"2027-01-01"}
        """#
        let guide = try JSONDecoder().decode(SoilGuide.self, from: Data(json.utf8))
        XCTAssertEqual(guide.sections.first?.id, "something-new")
        XCTAssertEqual(SoilWords.sourceMeta(try XCTUnwrap(guide.sections.first?.sources.first)), "МЗХ, 2027")
    }

    func testOnlyAWebAddressBecomesALink() {
        let source = SoilGuide.Source(id: "x", title: "Документ", publisher: "МЗХ", year: 2024, url: "javascript:alert(1)")
        XCTAssertNil(source.link)
    }

    func testThePathIsTheOpenFarmsAndBulgarian() {
        XCTAssertTrue(SoilGuideAPI.path.hasPrefix(FarmPath.prefix))
        XCTAssertTrue(SoilGuideAPI.path.hasSuffix("/knowledge/soil-guide?lang=bg"))
    }

    /// The assistant's soil answers link the web page; the phone opens its
    /// own «Почва» for that, with or without the farm in front of the route.
    @MainActor
    func testAnAnswerFromTheGuideOffersTheGuide() {
        let soil = AssistantLink(route: "/knowledge/soil", label: "Азотни торове: кога и колко")
        let withFarm = AssistantLink(route: "/t/synthetic-farm/knowledge/soil", label: "Почва")
        XCTAssertTrue(AssistantSheet.opensSoilGuide(soil))
        XCTAssertTrue(AssistantSheet.opensSoilGuide(withFarm))
        XCTAssertEqual(AssistantSheet.followable([soil], bar: [], farm: nil), [soil], "no farm or bar needed to read it")
        let other = AssistantLink(route: "/knowledge/satellite", label: "Сателит")
        XCTAssertFalse(AssistantSheet.opensSoilGuide(other))
        XCTAssertEqual(AssistantSheet.followable([other], bar: [], farm: "synthetic-farm"), [])
    }
}
