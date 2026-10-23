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

    /// Wheat arrives as USD per metric ton AND as EUR/t. The lead is chosen
    /// inside one (region, currency, unit) group, so a fresher USD print can
    /// never hand the headline a number in another currency.
    func testTheLeadNeverCrossesACurrency() async throws {
        let wheatJSON = """
        {"commodity":"wheat","range":"1y","generatedAt":"2026-09-22T20:03:25.529Z","series":[
          {"source":"alpha-vantage","region":"GLOBAL","stage":null,"unit":"dollar per metric ton","currency":"USD","label":"Reference (Alpha Vantage)","lastObservedAt":"2026-09-01","points":[{"date":"2026-09-01","price":228.74}]},
          {"source":"ec-agrifood","region":"BG","stage":"Burgas - DEPPROD","unit":"EUR/t","currency":"EUR","label":"Breadmaking common wheat","lastObservedAt":"2026-07-20","points":[{"date":"2026-07-20","price":177}]}
        ]}
        """
        let lead = try await decode(wheatJSON).lead
        XCTAssertEqual(lead?.currency, "EUR", "Bulgaria's EUR quote, not the fresher USD reference")
    }

    /// The platform's typed price leads (#1587): typed diesel is per litre,
    /// so it is in a group of its own, and it is the price the farm's figures
    /// use today.
    func testThePlatformsPriceLeads() async throws {
        let json = """
        {"commodity":"diesel","range":"1y","generatedAt":"2026-09-22T20:03:25.529Z","series":[
          {"source":"oil-bulletin","region":"BG","stage":"without-tax","unit":"EUR/1000l","currency":"EUR","label":"Automotive gas oil","lastObservedAt":"2026-09-14","points":[{"date":"2026-09-14","price":1216.62}]},
          {"source":"platform","region":"BG","stage":null,"unit":"EUR/l","currency":"EUR","label":null,"lastObservedAt":"2026-09-20","points":[{"date":"2026-09-20","price":1.42}]}
        ]}
        """
        let store = TrendsStore()
        store.setPricesForTesting(try await decode(json))
        XCTAssertEqual(store.lead?.source, "platform")
        XCTAssertEqual(SeriesVocabulary.unitHeading(unit: "EUR/l", currency: "EUR"), "евро на литър")
        XCTAssertEqual(store.lead?.headline(1.42), "1,42 евро на литър")
        XCTAssertEqual(SeriesSource.name(of: store.lead!), "Въведена от Agrent")
    }

    /// Diesel's two Bulgarian tax bases are one group; the lead is one of
    /// them, the same one on every open, and the row says which.
    func testOneOfTwoComplementsIsChosenStably() async throws {
        let first = try await decode(dieselJSON).lead
        let again = try await decode(dieselJSON).lead
        XCTAssertEqual(first?.region, "BG")
        XCTAssertEqual(first?.id, again?.id)
        XCTAssertTrue(["България · без данъци и акциз", "България · с данъци и акциз"]
            .contains(SeriesSource.name(of: first!)))
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

    // MARK: - Units (#121)
    //
    // One assertion per shape agri-saas can store — see the table on
    // `unitHeading`. None of them may say its currency twice, and none of
    // the known ones may reach the screen in English.

    private func heading(_ unit: String, _ currency: String) -> String {
        SeriesVocabulary.unitHeading(unit: unit, currency: currency)
    }

    /// EC cereals and Barchart MATIF: `EUR/t`.
    func testEuroPerTonne() {
        XCTAssertEqual(heading("EUR/t", "EUR"), "евро на тон")
    }

    /// EC oilseeds and the own-listings median: `<CUR>/t`, the currency
    /// resolved per member state. BGN is named; the rest keep their code
    /// rather than a guessed Bulgarian name — but still lose the doubling.
    func testNationalCurrencyPerTonne() {
        XCTAssertEqual(heading("BGN/t", "BGN"), "лева на тон")
        XCTAssertEqual(heading("RON/t", "RON"), "RON на тон")
        XCTAssertEqual(heading("HUF/t", "HUF"), "HUF на тон")
    }

    /// THE ONE IN THE ISSUE. The Oil Bulletin's diesel unit carries EUR,
    /// and Табло used to prefix the currency field to it anyway.
    func testDieselPerThousandLitres() {
        XCTAssertEqual(heading("EUR/1000l", "EUR"), "евро на 1000 литра")
        // The bulletin's own cell spelling, and a manual entry in lev.
        XCTAssertEqual(heading("EUR/1000 l", "EUR"), "евро на 1000 литра")
        XCTAssertEqual(heading("BGN/1000l", "BGN"), "лева на 1000 литра")
    }

    /// World Bank Pink Sheet — urea and DAP. `mt` is metric tonnes; before
    /// this it showed as «USD/mt» on a Bulgarian screen.
    func testFertiliserPerMetricTonne() {
        XCTAssertEqual(heading("USD/mt", "USD"), "долар на тон")
    }

    /// Alpha Vantage sends a phrase, and its client falls back to `USD/t`.
    /// The server's own test fixture spells the phrase with the ISO code.
    func testAlphaVantagePhrasesAndFallback() {
        XCTAssertEqual(heading("dollar per metric ton", "USD"), "долар на тон")
        XCTAssertEqual(heading("USD per metric ton", "USD"), "долар на тон")
        XCTAssertEqual(heading("USD/t", "USD"), "долар на тон")
    }

    func testPerHundredKilograms() {
        XCTAssertEqual(heading("EUR/100kg", "EUR"), "евро на 100 кг")
    }

    /// A bare measure (the app's own fixtures) takes the separate field.
    func testABareMeasureTakesTheCurrencyField() {
        XCTAssertEqual(heading("t", "EUR"), "евро на тон")
        XCTAssertEqual(heading("1000l", "EUR"), "евро на 1000 литра")
    }

    /// Case is not meaning for an ISO code — a manual entry typed `eur/t`.
    func testLowercaseCodesAreStillCodes() {
        XCTAssertEqual(heading("eur/t", "EUR"), "евро на тон")
    }

    /// `USd` is US CENTS. Treating it as USD is a factor of a hundred, so a
    /// mixed-case code is not parsed — it passes through as sent, and since
    /// it contains the field's letters it is not suffixed with them either.
    func testMinorUnitCodesAreNotReadAsTheCurrency() {
        XCTAssertEqual(heading("USd/bu", "USD"), "USd/bu")
        XCTAssertEqual(heading("USd/t", "USD"), "USd/t")
    }

    /// If the unit's currency and the field disagree, one of them is wrong
    /// and nothing here knows which. Both are shown rather than one chosen.
    func testADisagreeingCurrencyShowsBothAsSent() {
        XCTAssertEqual(heading("BGN/t", "EUR"), "BGN/t · EUR")
    }

    /// Unknown measure: verbatim, currency added only when it is missing —
    /// the doubling guard survives for units this does not recognise.
    func testUnknownUnitsPassThroughWithoutDoubling() {
        XCTAssertEqual(heading("MYR/bu", "MYR"), "MYR/bu")
        XCTAssertEqual(heading("bu", "USD"), "bu · USD")
        XCTAssertEqual(heading("head", "EUR"), "head · EUR")
    }

    /// Табло's headline goes through the same words. This is the string the
    /// issue saw as «1216,62 EUR/EUR/1000l».
    func testTheDashboardHeadlineDoesNotDoubleTheCurrency() throws {
        func series(_ unit: String, _ currency: String) throws -> PriceSeries {
            let json = """
            {"source":"s","region":"BG","stage":null,"unit":"\(unit)",
             "currency":"\(currency)","label":null,"lastObservedAt":null,"points":[]}
            """
            return try JSONDecoder().decode(PriceSeries.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try series("EUR/1000l", "EUR").headline(1216.62),
                       "\(Num.text(1216.62)) евро на 1000 литра")
        XCTAssertEqual(try series("EUR/t", "EUR").headline(208.62), "208,62 евро на тон")
        XCTAssertEqual(try series("t", "EUR").headline(208.62), "208,62 евро на тон")
        // Urea on Табло: World Bank is its only source, so the headline is
        // in dollars — and after a number Bulgarian counts in the plural.
        XCTAssertEqual(try series("USD/mt", "USD").headline(512), "512 долара на тон")
        XCTAssertEqual(try series("BGN/t", "BGN").headline(400), "400 лева на тон")
        // An unrecognised unit is still not doubled in the headline.
        XCTAssertEqual(try series("MYR/bu", "MYR").headline(9), "9 MYR/bu")
    }
}

/// The one price Тенденции and Табло quote (#409, owner 2026-10-23): the web's
/// rule, the national average first.
@MainActor
final class LeadSeriesTests: XCTestCase {

    private func series(_ source: String = "ec-agrifood", region: String = "BG", stage: String? = nil,
                        unit: String = "EUR/t", currency: String = "EUR", label: String? = nil,
                        observed: String, prices: [Double] = [180]) -> PriceSeries {
        let points = prices.enumerated().map { index, price in
            #"{"date":"2026-0\#(1 + index % 9)-01","price":\#(price)}"#
        }.joined(separator: ",")
        let stageJSON = stage.map { "\"\($0)\"" } ?? "null"
        let labelJSON = label.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"source":"\(source)","region":"\(region)","stage":\(stageJSON),"unit":"\(unit)","currency":"\(currency)",
         "label":\(labelJSON),"lastObservedAt":"\(observed)","points":[\(points)]}
        """
        return try! JSONDecoder().decode(PriceSeries.self, from: Data(json.utf8))
    }

    /// Wheat as production sends it, synthetic numbers: nine delivery points,
    /// the national average, the EU average and the USD reference.
    private func wheat(national: Bool = true) -> [PriceSeries] {
        var all = ["Burgas", "Dobrich", "Varna", "Ruse", "Pleven"].map {
            series(stage: "\($0) - DEPPROD", observed: "2026-07-20")
        }
        all.append(series(stage: "Departure from farm or from production area - on truck or other transport means",
                          observed: "2026-08-03"))
        if national { all.append(series(stage: "National Average - Not Specified", observed: "2026-07-27")) }
        all.append(series(region: "EU", stage: "EU average", observed: "2026-08-10"))
        all.append(series("alpha-vantage", region: "GLOBAL", unit: "dollar per metric ton", currency: "USD",
                          observed: "2026-09-01"))
        return all
    }

    /// The owner's choice over the freshest quotation, which here is three
    /// weeks newer: the national average answers "what is wheat worth".
    func testTheNationalAverageLeads() {
        let lead = wheat().lead()
        XCTAssertEqual(lead?.stage, "National Average - Not Specified")
        XCTAssertEqual(SeriesSource.name(of: lead!), "Средна за България")
    }

    /// Without one (sunflower has none), the freshest Bulgarian quotation.
    func testWithoutItTheFreshestBulgarianOne() {
        let lead = wheat(national: false).lead()
        XCTAssertEqual(lead?.region, "BG")
        XCTAssertTrue(lead?.stage?.hasPrefix("Departure from farm") ?? false)
        XCTAssertEqual(SeriesSource.name(of: lead!), "България · франко стопанство")
    }

    /// Bulgaria, then the EU average, then whichever group reported last.
    func testRegionsInOrder() {
        let noBulgaria = wheat().filter { $0.region != "BG" }
        XCTAssertEqual(noBulgaria.lead()?.region, "EU")
        let onlyGlobal = wheat().filter { $0.region == "GLOBAL" }
        XCTAssertEqual(onlyGlobal.lead()?.currency, "USD", "something rather than nothing")
    }

    /// Our own users' asking prices are not the market, unless they are all
    /// there is.
    func testOwnListingsAreALastResort() {
        let listings = series("listings", observed: "2026-09-20")
        let withQuote = [listings, series(region: "EU", observed: "2026-07-01")]
        XCTAssertEqual(withQuote.lead()?.source, "ec-agrifood")
        XCTAssertEqual([listings].lead()?.source, "listings")
    }

    func testNothingToQuote() {
        XCTAssertNil([series(observed: "2026-09-01", prices: [])].lead())
        XCTAssertNil([PriceSeries]().lead())
    }

    /// A tie resolves the same way whatever order the server sent.
    func testATieIsStable() {
        let a = series(stage: "Burgas - DEPPROD", observed: "2026-07-20")
        let b = series(stage: "Varna - DEPPROD", observed: "2026-07-20")
        XCTAssertEqual([a, b].lead()?.id, [b, a].lead()?.id)
    }

    // MARK: - The change over the period

    func testTheChangeIsFirstToLatest() throws {
        let rise = try XCTUnwrap(PeriodChange(series(observed: "2026-03-01", prices: [176, 180, 183.5])))
        XCTAssertEqual(rise.percent, (183.5 - 176) / 176 * 100, accuracy: 0.0001)
        XCTAssertEqual(rise.text(over: .year1), "▲ 4,3 % за 1 година")
        XCTAssertEqual(rise.spoken(over: .year1), "Нагоре с 4,3 процента за 1 година")
        let fall = try XCTUnwrap(PeriodChange(series(observed: "2026-02-01", prices: [200, 190])))
        XCTAssertEqual(fall.text(over: .month1), "▼ 5,0 % за 1 месец")
        let flat = try XCTUnwrap(PeriodChange(series(observed: "2026-02-01", prices: [200, 200.05])))
        XCTAssertEqual(flat.text(over: .month3), "Без промяна за 3 месеца")
    }

    func testOnePointHasNoChange() {
        XCTAssertNil(PeriodChange(series(observed: "2026-01-01", prices: [180])))
    }

    // MARK: - Where it comes from, in Bulgarian

    func testSourcesAreBulgarian() {
        XCTAssertEqual(SeriesSource.name(of: series(stage: "Burgas - DEPPROD", observed: "2026-07-20")), "Бургас")
        XCTAssertEqual(SeriesSource.name(of: series(stage: "Stara Zagora - DEPPROD", observed: "2026-07-20")),
                       "Стара Загора")
        XCTAssertEqual(SeriesSource.name(of: series("oil-bulletin", stage: "with-tax", observed: "2026-09-14")),
                       "България · с данъци и акциз")
        XCTAssertEqual(SeriesSource.name(of: series("listings", observed: "2026-09-14")), "Обявите в Agrent")
        XCTAssertEqual(SeriesSource.name(of: series("synthetic", label: "Синтетична борсова цена", observed: "2026-09-14")),
                       "България · Синтетична борсова цена")
    }

    /// An English stage or label the phone does not know is LEFT OUT: the
    /// region alone is true, an untranslated sentence is the defect.
    func testUnknownEnglishNeverReachesTheScreen() {
        let odd = series(stage: "Delivered free at frontier - by rail", label: "Breadmaking common wheat",
                         observed: "2026-07-20")
        XCTAssertEqual(SeriesSource.name(of: odd), "България")
        XCTAssertEqual(SeriesSource.name(of: series(stage: "Gotham - DEPPROD", observed: "2026-07-20")), "България")
    }
}
