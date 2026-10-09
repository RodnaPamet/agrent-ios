import XCTest
@testable import Agrent

/// Новини's topics (#231, agri-saas news contract #1446): what the feed asks
/// for, how a stale choice shows, what an article's tags are called — and
/// that the payloads decode, the old server's included.
final class NewsTopicsTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func catalogue() async throws -> NewsTagCatalogue {
        try await APIClient.shared.decode(try fixture("trends-news-tags"), as: NewsTagCatalogue.self)
    }

    // MARK: - What the feed asks for

    /// «Моите теми»: the chosen tags the catalogue knows, sorted. «Всички»,
    /// or nothing chosen, or never chosen: no tags — everything.
    func testTheFeedAsksForTheKnownChoicesInMyTopicsOnly() async throws {
        let known = try await catalogue()
        XCTAssertEqual(NewsTopics.requested(chosen: ["wheat", "subsidies", "renamed-away"],
                                            catalogue: known, scope: .mine),
                       ["subsidies", "wheat"])
        XCTAssertEqual(NewsTopics.requested(chosen: ["wheat"], catalogue: known, scope: .all), [])
        XCTAssertEqual(NewsTopics.requested(chosen: [], catalogue: known, scope: .mine), [])
        XCTAssertEqual(NewsTopics.requested(chosen: nil, catalogue: known, scope: .mine), [])
        // Before the catalogue is in hand, the choices go as they are: the
        // server ignores an unknown one.
        XCTAssertEqual(NewsTopics.requested(chosen: ["wheat", "barley"], catalogue: nil, scope: .mine),
                       ["barley", "wheat"])
    }

    /// Sorted tags, an escaped search, the cursor, the limit clamped — and no
    /// category: the screen filters on tags now.
    func testThePathCarriesTheFilters() {
        let path = TrendsAPI.newsPath(tags: ["wheat", "barley"], query: "пшеница", cursor: "c1")
        XCTAssertTrue(path.contains("tags=barley,wheat"), path)
        XCTAssertTrue(path.contains("q=%D0%BF"), path)
        XCTAssertTrue(path.contains("cursor=c1"), path)
        XCTAssertFalse(path.contains("category="), path)
        XCTAssertEqual(TrendsAPI.newsPath(tags: [], query: "  ", cursor: nil), TrendsAPI.newsPath(.all))
        XCTAssertTrue(TrendsAPI.newsPath(tags: [], query: nil, cursor: nil, limit: 500).contains("limit=100"))
    }

    // MARK: - Stale choices

    /// The echo is what the server applied: a tag it dropped shows as a
    /// difference. A server with no echo has nothing to compare.
    func testADroppedTagShowsInTheEcho() {
        XCTAssertFalse(NewsTopics.isStale(sent: ["subsidies", "wheat"], echo: ["wheat", "subsidies"]))
        XCTAssertTrue(NewsTopics.isStale(sent: ["subsidies", "wheat"], echo: ["wheat"]))
        XCTAssertTrue(NewsTopics.isStale(sent: ["old-tag"], echo: []), "all unknown: the feed came back unfiltered")
        XCTAssertFalse(NewsTopics.isStale(sent: ["wheat"], echo: nil))
    }

    func testAFlipAddsOrRemovesOneTag() {
        XCTAssertEqual(NewsTopics.toggled(nil, "wheat"), ["wheat"])
        XCTAssertEqual(NewsTopics.toggled(["wheat", "prices"], "wheat"), ["prices"])
        XCTAssertEqual(NewsTopics.toggled(["wheat"], "barley"), ["barley", "wheat"])
    }

    // MARK: - An article's tags

    /// Named by the catalogue, in its order; a key it does not hold is left
    /// out rather than shown as code.
    func testAnArticlesTagsAreTheCataloguesNames() async throws {
        let known = try await catalogue()
        let names = NewsTopics.labels(["weather", "frost-alerts", "wheat"], in: known).map(\.label)
        XCTAssertEqual(names, ["Пшеница", "Време"])
        XCTAssertEqual(NewsTopics.labels(nil, in: known), [])
        // `[]` is «matched no rule», not «not yet classified» (agri-saas
        // #1466): no chips, and nothing that reads as loading or failing —
        // «Всички» is what keeps such an article reachable.
        XCTAssertEqual(NewsTopics.labels([], in: known), [])
        XCTAssertEqual(NewsTopics.labels(["wheat"], in: nil), [])
        XCTAssertEqual(known.tag("inputs")?.labelEn, "Fertilisers and sprays")
    }

    // MARK: - The payloads

    /// The feed decodes with the echo and without it — an older server, or
    /// the installed build's, sends neither `tags` nor `nextCursor`.
    func testTheFeedDecodesWithAndWithoutTheEcho() async throws {
        let mine = try await APIClient.shared.decode(try fixture("trends-news-mine"), as: NewsResponse.self)
        XCTAssertEqual(mine.tags, ["subsidies", "wheat"])
        XCTAssertEqual(mine.items.first?.tags, ["wheat", "prices"])
        let old = Data(#"{"category":"all","items":[{"id":"n1","source":"S","category":"market","title":"T","summary":null,"url":"https://example.invalid/a","imageUrl":null,"publishedAt":"2026-10-08T08:00:00.000Z"}]}"#.utf8)
        let page = try await APIClient.shared.decode(old, as: NewsResponse.self)
        XCTAssertNil(page.tags)
        XCTAssertNil(page.nextCursor)
        XCTAssertNil(page.items.first?.tags)
    }

    /// `null` is «never chose», `[]` «chose nothing» — both decode.
    func testThePreferencesDecodeNullAndEmpty() async throws {
        for (json, expected) in [(#"{"tags":null}"#, nil), (#"{"tags":[]}"#, [String]()), (#"{"tags":["wheat"]}"#, ["wheat"])] as [(String, [String]?)] {
            let body = try await APIClient.shared.decode(Data(json.utf8), as: NewsPreferencesAPI.Body.self)
            XCTAssertEqual(body.tags, expected, json)
        }
    }
}
