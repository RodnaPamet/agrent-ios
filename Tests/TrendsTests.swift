import XCTest
@testable import Agrent

final class ChartableCommodityTests: XCTestCase {

    /// The nine the feeds actually quote, written out literally.
    private let chartable = [
        "wheat", "maize", "barley", "sunflower",
        "diesel", "urea", "dap", "map", "ammonium-nitrate",
    ]

    func testExactlyTheChartableNine() {
        XCTAssertEqual(Set(ChartableCommodity.allCases.map(\.rawValue)), Set(chartable))
    }

    /// The six that would 400. `rapeseed` is verified against production:
    ///     rapeseed ERROR http(status: 400, code: nil, message: nil)
    func testTheUnquotedSixAreNotOffered() {
        let offered = Set(ChartableCommodity.allCases.map(\.rawValue))
        for slug in ["rapeseed", "oats", "rye", "soybean", "peas", "lentils"] {
            XCTAssertFalse(offered.contains(slug), "\(slug) is in the exchange vocabulary, not the feeds")
            // …and is still a real commodity with a real name elsewhere.
            XCTAssertNotNil(CommodityName.canonical(slug), "\(slug) should still have a label")
        }
    }

    func testEveryChartableOneHasABulgarianLabel() {
        for item in ChartableCommodity.allCases {
            XCTAssertNotEqual(item.label, item.rawValue, "\(item.rawValue) is untranslated")
            XCTAssertFalse(item.label.isEmpty)
        }
    }

    func testCropsAndInputsSplitFourAndFive() {
        XCTAssertEqual(ChartableCommodity.allCases.filter { !$0.isInput }.count, 4)
        XCTAssertEqual(ChartableCommodity.allCases.filter(\.isInput).count, 5)
    }

    func testPathsCarryCommodityAndRange() {
        let path = TrendsAPI.pricesPath(.ammoniumNitrate, range: .month3)
        XCTAssertTrue(path.contains("commodity=ammonium-nitrate"), path)
        XCTAssertTrue(path.contains("range=3m"), path)
    }

    /// `all` is the server's own word for no category filter, so sending it
    /// would be redundant at best.
    func testNewsPathOmitsTheAllCategory() {
        XCTAssertFalse(TrendsAPI.newsPath(.all).contains("category="))
        XCTAssertTrue(TrendsAPI.newsPath(.policy).contains("category=policy"))
    }

    func testNewsLimitIsClampedToTheServersRange() {
        XCTAssertTrue(TrendsAPI.newsPath(.all, limit: 500).contains("limit=100"))
        XCTAssertTrue(TrendsAPI.newsPath(.all, limit: 0).contains("limit=1"))
    }
}

/// The contract said series are grouped by (source, region). Production
/// says otherwise, and the difference is a fifty per cent error in the
/// price of diesel.
@MainActor
final class PriceSeriesIdentityTests: XCTestCase {

    /// Captured from production, trimmed to two points each.
    private let dieselJSON = """
    {"commodity":"diesel","range":"3m","generatedAt":"2026-09-22T20:03:25.712Z","series":[
      {"source":"oil-bulletin","region":"BG","stage":"without-tax","unit":"EUR/1000l","currency":"EUR","label":"Automotive gas oil (excluding duties and taxes)","lastObservedAt":"2026-09-14","points":[{"date":"2026-09-07","price":1180.46},{"date":"2026-09-14","price":1216.62}]},
      {"source":"oil-bulletin","region":"BG","stage":"with-tax","unit":"EUR/1000l","currency":"EUR","label":"Automotive gas oil (with duties and taxes)","lastObservedAt":"2026-09-14","points":[{"date":"2026-09-07","price":1812.9},{"date":"2026-09-14","price":1856.3}]},
      {"source":"oil-bulletin","region":"EL","stage":"without-tax","unit":"EUR/1000l","currency":"EUR","label":"Automotive gas oil (excluding duties and taxes)","lastObservedAt":"2026-09-14","points":[{"date":"2026-09-14","price":1286.96}]}
    ]}
    """

    private func decode(_ json: String) async throws -> PricesResponse {
        try await APIClient.shared.decode(Data(json.utf8), as: PricesResponse.self)
    }

    /// THE CORRECTION. Same source, same region, different stage, and a
    /// difference of 639.68 EUR per 1000 litres between them.
    func testStageIsPartOfSeriesIdentity() async throws {
        let response = try await decode(dieselJSON)
        let bulgarian = response.series.filter { $0.region == "BG" }
        XCTAssertEqual(bulgarian.count, 2)
        XCTAssertEqual(bulgarian[0].source, bulgarian[1].source)
        XCTAssertEqual(bulgarian[0].region, bulgarian[1].region)
        XCTAssertNotEqual(bulgarian[0].id, bulgarian[1].id,
                          "keyed without stage, with-tax and without-tax collide")
    }

    /// The consequence, stated as money: a client that merged these would
    /// show one of two numbers half an order apart as "the" diesel price.
    func testTheCollidingSeriesDifferByHalfAgain() async throws {
        let response = try await decode(dieselJSON)
        let bulgarian = response.series.filter { $0.region == "BG" }
        let prices = bulgarian.compactMap { $0.points.last?.price }.sorted()
        XCTAssertEqual(prices.count, 2)
        XCTAssertGreaterThan(prices[1] / prices[0], 1.5)
    }

    func testEverySeriesIDIsDistinct() async throws {
        let ids = try await decode(dieselJSON).series.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Wheat arrives as USD per metric ton AND as EUR/t. On one axis the
    /// gap between them draws as a price movement when it is a exchange
    /// rate — the same rule the exchange map enforces.
    func testCurrenciesAreNeverGroupedTogether() async throws {
        let wheatJSON = """
        {"commodity":"wheat","range":"1y","generatedAt":"2026-09-22T20:03:25.529Z","series":[
          {"source":"alpha-vantage","region":"GLOBAL","stage":null,"unit":"dollar per metric ton","currency":"USD","label":"Reference (Alpha Vantage)","lastObservedAt":"2026-07-01","points":[{"date":"2026-07-01","price":228.74}]},
          {"source":"ec-agrifood","region":"BG","stage":"Burgas - DEPPROD","unit":"EUR/t","currency":"EUR","label":"Breadmaking common wheat","lastObservedAt":"2026-07-20","points":[{"date":"2026-07-20","price":177}]}
        ]}
        """
        let store = TrendsStore()
        store.setPricesForTesting(try await decode(wheatJSON))
        XCTAssertEqual(store.groups.count, 2, "USD and EUR must not share a chart")
        for group in store.groups {
            XCTAssertEqual(Set(group.series.map(\.currency)).count, 1)
            XCTAssertEqual(Set(group.series.map(\.unit)).count, 1)
        }
    }

    /// Four diesel series, one unit, one currency — so ONE chart. The rule
    /// splits on currency, not on series count, and a test that only ever
    /// saw the splitting case would not prove that.
    func testOneCurrencyStaysOneChart() async throws {
        let store = TrendsStore()
        store.setPricesForTesting(try await decode(dieselJSON))
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.series.count, 3)
    }

    /// Hiding every line leaves a full legend over an empty chart, which
    /// reads as a load failure.
    func testTheLastVisibleSeriesCannotBeHidden() async throws {
        let store = TrendsStore()
        store.setPricesForTesting(try await decode(dieselJSON))
        let series = store.groups.first!.series
        for one in series { store.toggle(one) }
        XCTAssertEqual(series.filter(store.isVisible).count, 1)
    }
}

/// Freshness comes from two SERVER values. The device clock must not reach it.
final class StalenessTests: XCTestCase {

    private var original: TimeZone!

    override func setUp() {
        super.setUp()
        original = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = original
        super.tearDown()
    }

    private func instant(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    /// The real case, and the reason this is shown in orange: wheat's
    /// reference series was last observed on 1 July under a payload built
    /// on 22 September.
    func testTheEightyThreeDayWheatSeries() throws {
        let days = Staleness.days(
            generatedAt: try instant("2026-09-22T20:03:25Z"),
            lastObservedAt: "2026-07-01")
        XCTAssertEqual(days, 83)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(days), Staleness.concerning)
    }

    func testAFreshSeriesIsEightDays() throws {
        XCTAssertEqual(
            Staleness.days(generatedAt: try instant("2026-09-22T20:03:25Z"),
                           lastObservedAt: "2026-09-14"),
            8)
    }

    /// THE ONE THAT CATCHES A REGRESSION TO THE DEVICE CLOCK.
    ///
    /// 22:30 UTC on the 22nd is already the 23rd in Tokyo. A `Calendar
    /// .current` implementation returns 1 here; a UTC one returns 0. Both
    /// look equally plausible reading the code, which is why this asserts
    /// it with the device moved rather than by inspection.
    func testTheDeviceTimeZoneCannotChangeTheAnswer() throws {
        let generatedAt = try instant("2026-09-22T22:30:00Z")
        var answers: Set<Int> = []
        for zone in ["UTC", "Asia/Tokyo", "Pacific/Honolulu", "Europe/Sofia"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let days = try XCTUnwrap(
                Staleness.days(generatedAt: generatedAt, lastObservedAt: "2026-09-22"))
            answers.insert(days)
        }
        XCTAssertEqual(answers, [0], "the device time zone changed a server-side measurement")
    }

    func testNeverObservedIsNilRatherThanZero() throws {
        // Zero would render as "observed today", which is the opposite.
        XCTAssertNil(Staleness.days(generatedAt: try instant("2026-09-22T20:03:25Z"),
                                    lastObservedAt: nil))
        XCTAssertNil(Staleness.days(generatedAt: try instant("2026-09-22T20:03:25Z"),
                                    lastObservedAt: "не знам"))
    }
}

@MainActor
final class NewsItemTests: XCTestCase {

    private func item(summary: String?) async throws -> NewsItem {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "x", "source": "agrovest", "category": "general",
            "title": "T", "summary": summary as Any, "url": "https://example.com",
            "imageUrl": NSNull(), "publishedAt": "2026-09-22T05:39:03.000Z",
        ])
        return try await APIClient.shared.decode(json, as: NewsItem.self)
    }

    /// Both feeds append this, on every item, after a newline.
    func testTheFeedFooterIsRemoved() async throws {
        let one = try await item(summary: "Към 21 септември украинските фермери са вършели 9,4 милиона хектара...\nМатериалът Соята и слънчогледът ускориха жътвата в Украйна е публикуван за пръв път на Агровест.")
        XCTAssertEqual(one.cleanedSummary, "Към 21 септември украинските фермери са вършели 9,4 милиона хектара...")

        let two = try await item(summary: "БАБХ установи шарка по дребните преживни животни […]\nПубликация Централна емисия новини се показа за първи път в AGRO TV")
        XCTAssertEqual(two.cleanedSummary, "БАБХ установи шарка по дребните преживни животни […]")
    }

    /// Narrow on purpose. The word mid-sentence is not a footer.
    func testAMentionMidTextSurvives() async throws {
        let kept = try await item(summary: "Публикация в Държавен вестник промени сроковете.")
        XCTAssertEqual(kept.cleanedSummary, "Публикация в Държавен вестник промени сроковете.")
    }

    func testNullSummaryStaysNil() async throws {
        let empty = try await item(summary: nil)
        XCTAssertNil(empty.cleanedSummary)
    }

    /// A summary that is nothing BUT the footer becomes nil, not "".
    func testAFooterOnlySummaryIsNil() async throws {
        let footerOnly = try await item(summary: "Материалът X е публикуван за пръв път на Агровест.")
        XCTAssertNil(footerOnly.cleanedSummary)
    }

    /// An unknown category must not fail the decode of the whole list —
    /// the `LogEntryType` lesson, where six client cases against ten
    /// server values would have taken every row with the first surprise.
    func testAnUnknownCategoryStillDecodes() async throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "x", "source": "s", "category": "weather",
            "title": "T", "url": "https://example.com",
            "publishedAt": "2026-09-22T05:39:03.000Z",
        ])
        let decoded = try await APIClient.shared.decode(json, as: NewsItem.self)
        XCTAssertEqual(decoded.category, "weather")
        XCTAssertNil(decoded.categoryLabel, "unknown categories get no invented label")
    }
}

final class SeriesVocabularyTests: XCTestCase {

    func testKnownStagesAreTranslated() {
        XCTAssertEqual(SeriesVocabulary.stage("with-tax"), "с данъци и акциз")
        XCTAssertEqual(SeriesVocabulary.stage("without-tax"), "без данъци и акциз")
    }

    /// `"Burgas - DEPPROD"` is a real stage from the EC feed. Passing it
    /// through is better than inventing a Bulgarian rendering of a code
    /// nobody here defined.
    func testUnknownStagesPassThrough() {
        XCTAssertEqual(SeriesVocabulary.stage("Burgas - DEPPROD"), "Burgas - DEPPROD")
        XCTAssertNil(SeriesVocabulary.stage(nil))
        XCTAssertNil(SeriesVocabulary.stage(""))
    }

    func testRegionsThatMatterAreNamed() {
        XCTAssertEqual(SeriesVocabulary.region("BG"), "България")
        XCTAssertEqual(SeriesVocabulary.region("GLOBAL"), "Световен")
        XCTAssertEqual(SeriesVocabulary.region("EL"), "Гърция")
    }

    func testUnknownRegionsKeepTheirCode() {
        XCTAssertEqual(SeriesVocabulary.region("SK"), "SK")
    }
}

/// Default visibility, and the fact that it stops once the reader has an
/// opinion.
@MainActor
final class SeriesVisibilityTests: XCTestCase {

    /// Wheat's EUR/t group really does carry 23 series — the EC agri-food
    /// feed quotes every member state, nine of them in Bulgaria. Shaped
    /// like the real payload, at that scale.
    private func manySeries() -> PricesResponse {
        var series: [PriceSeries] = []
        let regions = ["BG", "BG", "BG", "BG", "BG", "BG", "BG", "BG", "BG",
                       "RO", "HU", "PL", "FR", "DE", "EL"]
        for (index, region) in regions.enumerated() {
            let json = """
            {"source":"ec-agrifood","region":"\(region)","stage":"stage-\(index)",
             "unit":"EUR/t","currency":"EUR","label":"L\(index)",
             "lastObservedAt":"2026-0\(1 + index % 9)-01",
             "points":[{"date":"2026-01-01","price":\(170 + index)}]}
            """
            series.append(try! JSONDecoder().decode(PriceSeries.self, from: Data(json.utf8)))
        }
        return PricesResponse(
            commodity: "wheat", range: "1y",
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000), series: series)
    }

    func testTheDefaultIsThreeLinesNotTwentyThree() {
        let store = TrendsStore()
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        let group = store.groups.first!
        XCTAssertEqual(group.series.count, 15)
        XCTAssertEqual(group.series.filter(store.isVisible).count, 3)
    }

    /// Bulgaria first — this is a Bulgarian farm.
    func testTheDefaultPrefersBulgaria() {
        let store = TrendsStore()
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        let shown = store.groups.first!.series.filter(store.isVisible)
        XCTAssertTrue(shown.allSatisfy { $0.region == "BG" }, shown.map(\.region).description)
    }

    /// Freshest first: a series that stopped in spring says less about
    /// today than one observed last week.
    func testTheDefaultPrefersTheMostRecentlyObserved() {
        let store = TrendsStore()
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        let shown = store.groups.first!.series.filter(store.isVisible)
        let hiddenBG = store.groups.first!.series
            .filter { $0.region == "BG" && !store.isVisible($0) }
        let newestHidden = hiddenBG.compactMap(\.lastObservedAt).max() ?? ""
        for one in shown {
            XCTAssertGreaterThanOrEqual(one.lastObservedAt ?? "", newestHidden)
        }
    }

    /// THE ONE THE COMMENT WAS WRONG ABOUT.
    ///
    /// `applyDefaultVisibility` runs on every load, so changing the range
    /// re-derived the defaults and silently undid the reader's choice of
    /// lines. The comment on `select(_ range:)` said the choice survived.
    /// It did not.
    func testAHandPickedSelectionSurvivesAReload() async {
        let store = TrendsStore()
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        let hiddenOne = store.groups.first!.series.first { !store.isVisible($0) }!
        store.toggle(hiddenOne)
        XCTAssertTrue(store.isVisible(hiddenOne))

        // A second payload arriving — what a range change does.
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        XCTAssertTrue(store.isVisible(hiddenOne),
                      "reloading threw away the reader's choice of series")
    }

    /// Changing commodity DOES reset: a series id from wheat means nothing
    /// under diesel.
    func testChangingCommodityResetsTheChoice() async {
        let store = TrendsStore()
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        let hiddenOne = store.groups.first!.series.first { !store.isVisible($0) }!
        store.toggle(hiddenOne)
        store.commodity = .diesel
        store.resetSeriesChoiceForTesting()
        store.setPricesForTesting(manySeries(), applyDefaults: true)
        XCTAssertFalse(store.isVisible(hiddenOne))
    }
}
