import XCTest
@testable import Agrent

/// A parcel's readings over a period (#562): the change in words, the
/// chart's breaks at cloudy passes, and the two ways there is no line.
@MainActor
final class RiskTrendTests: XCTestCase {

    private func fixture() async throws -> ParcelRiskHistory {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "risk-history-holes", withExtension: "json"))
        return try await RiskTrendAPI.decode(Data(contentsOf: url))
    }

    private func history(days: Int = 14, configured: Bool = true,
                         _ readings: [(String, Double?, Double?)]) -> ParcelRiskHistory {
        ParcelRiskHistory(days: days, configured: configured, truncated: false, passes: readings.map {
            .init(date: $0.0, ndvi: $0.1, ndmi: $0.2, vegetation: .good, moisture: .good, source: nil)
        })
    }

    func testThePathAsksForThePeriod() {
        XCTAssertTrue(RiskTrendAPI.path("par_holes", days: 30)
            .hasSuffix("/agro/parcels/par_holes/analysis/history?days=30"))
        XCTAssertEqual(RiskTrendAPI.periods, [14, 30, 60])
    }

    func testTheFixtureReadsWithItsCloudyPass() async throws {
        let history = try await fixture()
        XCTAssertEqual(history.days, 14)
        XCTAssertEqual(history.passes.count, 6)
        XCTAssertNil(history.passes[2].ndvi, "a cloudy pass stays null, never 0")
        XCTAssertEqual(history.passes[2].vegetation, .unknown)
    }

    func testTheChangeIsSaidFromFirstToLastClearPass() async throws {
        let words = RiskTrendWords.change(try await fixture())
        XCTAssertEqual(words, "За 14 дни зеленината спадна от 0,78 до 0,71 (−9\u{00A0}%), а влагата спадна от 0,33 до 0,28 (−14\u{00A0}%).")
    }

    /// The days are the server's: it clamps, and the sentence says what it used.
    func testTheDaysAreTheServers() {
        let words = RiskTrendWords.change(history(days: 120, [("2026-09-01", 0.5, nil), ("2026-09-20", 0.6, nil)]))
        XCTAssertEqual(words, "За 120 дни зеленината се повиши от 0,50 до 0,60 (+20\u{00A0}%).")
    }

    func testNoMovementIsSaidAsSteady() {
        let words = RiskTrendWords.change(history([("2026-09-01", 0.712, nil), ("2026-09-20", 0.718, nil)]))
        XCTAssertEqual(words, "За 14 дни зеленината остана около 0,72.")
    }

    /// NDMI near 0: a percentage from a base that small says nothing.
    func testNoPercentageFromABaseNearZero() {
        let words = RiskTrendWords.change(history([("2026-09-01", nil, 0.02), ("2026-09-20", nil, 0.1)]))
        XCTAssertEqual(words, "За 14 дни влагата се повиши от 0,02 до 0,10.")
    }

    func testOneClearPassIsNoChange() {
        XCTAssertNil(RiskTrendWords.change(history([("2026-09-01", 0.7, 0.3), ("2026-09-05", nil, nil)])))
    }

    /// Not set up and all cloudy are different news, said differently.
    func testTheTwoEmptiesAreSaidApart() {
        let off = history(configured: false, [])
        XCTAssertEqual(RiskTrendWords.empty(off), "Сателитният анализ не е настроен, затова няма история.")
        let cloudy = history([("2026-09-01", nil, nil)])
        XCTAssertEqual(RiskTrendWords.empty(cloudy), "Няма ясна сателитна снимка за последните 14 дни.")
        XCTAssertEqual(RiskTrendWords.empty(history([])), "Няма ясна сателитна снимка за последните 14 дни.")
        XCTAssertNil(RiskTrendWords.empty(history([("2026-09-01", 0.7, nil)])))
    }

    /// A cloudy pass starts a new series, so the line breaks there.
    func testACloudyPassBreaksTheLine() async throws {
        let points = RiskTrendPoints.points(try await fixture())
        let ndvi = points.filter { $0.index == .ndvi }
        XCTAssertEqual(ndvi.count, 5)
        XCTAssertEqual(ndvi.map(\.series), ["ndvi-0", "ndvi-0", "ndvi-1", "ndvi-1", "ndvi-1"])
        XCTAssertFalse(points.contains { $0.value == 0 }, "no gap drawn as 0")
        XCTAssertEqual(Set(points.map(\.id)).count, points.count, "ids unique across both indices")
    }

    func testTheScaleReachesBelowZeroOnlyWhenAReadingDoes() {
        let dry = RiskTrendPoints.points(history([("2026-09-01", 0.2, -0.13), ("2026-09-05", 0.3, -0.05)]))
        XCTAssertEqual(RiskTrendPoints.domain(dry), -0.2...1)
        let green = RiskTrendPoints.points(history([("2026-09-01", 0.7, 0.3)]))
        XCTAssertEqual(RiskTrendPoints.domain(green), 0...1)
    }

    /// The assistant is asked about the same days the screen shows.
    func testTheQuestionCarriesTheTrend() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "risk-analysis-holes", withExtension: "json"))
        let risk = try await FarmRiskAPI.decodeAnalysis(from: Data(contentsOf: url))
        let trend = RiskTrendWords.change(try await fixture())
        let question = RiskAnalysisQuestion.text(parcel: "SYNTH-1", risk: risk, freshness: nil, trend: trend,
                                                 seasons: [], operations: [], weeds: [])
        XCTAssertTrue(question.contains("За 14 дни зеленината спадна"), question)
    }
}
