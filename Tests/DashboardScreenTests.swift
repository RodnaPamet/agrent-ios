import XCTest
@testable import Agrent

/// «Табло»: the farmer's choice of blocks, and the one price it shows.
@MainActor
final class DashboardScreenTests: XCTestCase {

    // MARK: - The owner's arrangement

    /// The four the owner chose on 2026-09-25 when offered all seven.
    func testTheDefaultBlocksAreTheOwnersFour() {
        XCTAssertEqual(DashboardBlock.defaultOrder,
                       [.briefing, .grainPrice, .journal, .taskTrend])
        // The other three exist so the picker can offer them without a build.
        XCTAssertEqual(DashboardBlock.allCases.count, 7)
    }

    /// Turning a block on puts it at the END, where somebody expects a new
    /// thing — not into the middle by enum order, which would rearrange a
    /// screen they had already arranged.
    func testTogglingOnAppendsRatherThanReordering() {
        let prefs = DashboardPreferences.ephemeral(blocks: [.briefing, .journal])
        prefs.toggle(.tasks)
        XCTAssertEqual(prefs.blocks, [.briefing, .journal, .tasks])

        prefs.toggle(.briefing)
        XCTAssertEqual(prefs.blocks, [.journal, .tasks])
        XCTAssertFalse(prefs.isOn(.briefing))
    }

    func testOrderSurvivesAMove() {
        let prefs = DashboardPreferences.ephemeral(blocks: [.briefing, .journal, .taskTrend])
        prefs.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(prefs.blocks, [.taskTrend, .briefing, .journal])
    }

    /// A block removed in a later build must not strand a saved arrangement —
    /// the same rule `AppSurface` applies to a bar order saved on the web,
    /// where an unknown suffix drops out rather than failing the load.
    func testAnUnknownStoredBlockIsDroppedRatherThanFatal() {
        let restored = ["briefing", "somethingRemovedLater", "journal"]
            .compactMap(DashboardBlock.init(rawValue:))
        XCTAssertEqual(restored, [.briefing, .journal])
    }

    // MARK: - Which price, out of how many

    private func series(_ source: String, region: String, stage: String? = nil,
                        unit: String = "t", currency: String = "EUR",
                        lastObserved: String?, points: Int) -> PriceSeries {
        let json = """
        {"source":"\(source)","region":"\(region)",
         "stage":\(stage.map { "\"\($0)\"" } ?? "null"),
         "unit":"\(unit)","currency":"\(currency)","label":null,
         "lastObservedAt":\(lastObserved.map { "\"\($0)\"" } ?? "null"),
         "points":[\((0..<points).map { #"{"date":"2026-09-\#(String(format: "%02d", $0 + 1))","price":200.0,"count":null}"# }.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(PriceSeries.self, from: Data(json.utf8))
    }

    private func response(_ list: [PriceSeries]) -> PricesResponse {
        PricesResponse(commodity: "wheat", range: "3m",
                       generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                       series: list)
    }

    /// A BULGARIAN series beats a foreign one, because "the" price means the one
    /// this farm is in — the EC feed quotes other member states.
    func testTheBulgarianSeriesIsPreferred() {
        let chosen = response([
            series("ec", region: "EL", lastObserved: "2026-09-25", points: 20),
            series("ec", region: "BG", lastObserved: "2026-09-20", points: 20),
        ]).dashboardSeries
        XCTAssertEqual(chosen?.series.region, "BG")
        XCTAssertEqual(chosen?.outOf, 2)
    }

    /// Freshest first, then the longest record: a series observed last week says
    /// more about today than one that stopped in spring, and between two equally
    /// current ones the longer history is the better line.
    func testFreshestThenLongest() {
        let chosen = response([
            series("a", region: "BG", lastObserved: "2026-05-01", points: 200),
            series("b", region: "BG", lastObserved: "2026-09-25", points: 8),
        ]).dashboardSeries
        XCTAssertEqual(chosen?.series.source, "b")

        let tie = response([
            series("short", region: "BG", lastObserved: "2026-09-25", points: 8),
            series("long", region: "BG", lastObserved: "2026-09-25", points: 80),
        ]).dashboardSeries
        XCTAssertEqual(tie?.series.source, "long")
    }

    /// THE ONE THAT KEEPS THE NUMBER HONEST.
    ///
    /// Grouped by (unit, currency) before ranking, and the LARGEST group wins.
    /// Otherwise a single fresher outlier in another currency takes the block —
    /// a USD monthly print displacing the weekly EUR series a Bulgarian farm
    /// actually sells against, with nothing on screen to say the number changed
    /// currency.
    func testAFresherOutlierInAnotherCurrencyDoesNotWin() {
        let chosen = response([
            series("ec", region: "BG", stage: "delivered", currency: "EUR",
                   lastObserved: "2026-09-20", points: 40),
            series("ec", region: "BG", stage: "exw", currency: "EUR",
                   lastObserved: "2026-09-18", points: 40),
            series("av", region: "GLOBAL", currency: "USD",
                   lastObserved: "2026-09-25", points: 12),
        ]).dashboardSeries

        XCTAssertEqual(chosen?.series.currency, "EUR")
        XCTAssertEqual(chosen?.outOf, 3, "it still says it is one of three")
    }

    /// A series with no observations has no latest price, so it cannot be the
    /// one shown — and a response of nothing but empty series shows no block at
    /// all rather than an empty card.
    func testSeriesWithNoPointsCannotBeChosen() {
        let chosen = response([
            series("fresh-but-empty", region: "BG", lastObserved: "2026-09-25", points: 0),
            series("older-with-data", region: "BG", lastObserved: "2026-09-01", points: 10),
        ]).dashboardSeries
        XCTAssertEqual(chosen?.series.source, "older-with-data")
        XCTAssertEqual(chosen?.outOf, 1)

        XCTAssertNil(response([
            series("empty", region: "BG", lastObserved: "2026-09-25", points: 0),
        ]).dashboardSeries)
        XCTAssertNil(response([]).dashboardSeries)
    }

    /// Stable across launches. Two groups of equal size must not swap by
    /// dictionary order — a block that shows a different series every time it
    /// opens is worse than either series alone.
    func testAnEqualSizedTieIsStable() {
        let list = [
            series("eur", region: "BG", currency: "EUR", lastObserved: "2026-09-25", points: 10),
            series("usd", region: "BG", currency: "USD", lastObserved: "2026-09-25", points: 10),
        ]
        let first = response(list).dashboardSeries?.series.id
        for _ in 0..<50 {
            XCTAssertEqual(response(list).dashboardSeries?.series.id, first)
            XCTAssertEqual(response(list.reversed()).dashboardSeries?.series.id, first)
        }
    }

    /// The extracted ranking is what the Тенденции chart uses, so the two
    /// screens cannot disagree about which series leads. Falls back to the whole
    /// list rather than to nothing when no BG or GLOBAL series exists — an empty
    /// chart under a full legend is worse than a foreign price honestly labelled.
    func testRankingFallsBackRatherThanReturningNothing() {
        let foreign = [
            series("ec", region: "EL", lastObserved: "2026-09-25", points: 10),
            series("ec", region: "RO", lastObserved: "2026-09-26", points: 10),
        ]
        XCTAssertEqual(foreign.rankedForDefaultDisplay().count, 2)
        XCTAssertEqual(foreign.rankedForDefaultDisplay().first?.region, "RO")
    }
}
