import XCTest
@testable import Agrent

/// How even a parcel is (#562 stage 2): said over the VISIBLE part, never
/// the whole parcel, as cloud is masked out of every figure.
final class RiskWithinFieldTests: XCTestCase {

    private let nbsp = "\u{00A0}"

    private func field(p10: Double? = 0.6, p50: Double? = 0.7, p90: Double? = 0.8,
                       share: Double? = 0.07, coverage: Double? = nil) -> ParcelRisk.WithinField {
        .init(ndviP10: p10, ndviP50: p50, ndviP90: p90, belowThresholdShare: share, threshold: 0.35,
              coverage: coverage)
    }

    func testTheShareIsOfTheVisiblePart() {
        let words = RiskWithinField.sentences(field(), mean: 0.7)
        XCTAssertEqual(words, ["7\(nbsp)% от видимата част на парцела е под прага на стрес (NDVI 0,35)."])
        XCTAssertFalse(words.joined().contains("% от парцела"), "never a share of the whole parcel")
    }

    func testNoneAndATraceAreSaidInWords() {
        XCTAssertEqual(RiskWithinField.sentences(field(share: 0), mean: 0.7),
                       ["Нищо от видимата част на парцела не е под прага на стрес (NDVI 0,35)."])
        XCTAssertEqual(RiskWithinField.sentences(field(share: 0.004), mean: 0.7).first,
                       "Под 1\(nbsp)% от видимата част на парцела е под прага на стрес (NDVI 0,35).")
    }

    /// A mean well below the median: a small very weak part, a patch to find.
    func testAMeanBelowTheMedianPointsAtAPatch() {
        let words = RiskWithinField.sentences(field(p10: 0.2, p50: 0.74, p90: 0.85), mean: 0.66)
        XCTAssertEqual(words.last, "Средната стойност е свалена от малка, много слаба част: огледайте полето за петна.")
        XCTAssertEqual(words.count, 2, "the patch sentence replaces the uneven one, not both")
    }

    func testAWideSpreadIsUneven() {
        let words = RiskWithinField.sentences(field(p10: 0.41, p50: 0.74, p90: 0.88), mean: 0.712)
        XCTAssertEqual(words.last, "Полето е неравномерно: най-слабата десета част е под 0,41, най-силната над 0,88.")
    }

    /// Coverage is said only when it is short, and as of the whole parcel.
    func testShortCoverageIsSaidFullIsQuiet() {
        XCTAssertEqual(RiskWithinField.sentences(field(coverage: 0.6), mean: 0.7).last,
                       "Сателитът е видял само 60\(nbsp)% от парцела през периода; за останалото няма ясен изглед.")
        XCTAssertFalse(RiskWithinField.sentences(field(coverage: 0.6), mean: 0.7).joined().contains("облак"),
                       "snow and missing passes are masked too: no cause is named")
        XCTAssertEqual(RiskWithinField.sentences(field(coverage: 0.98), mean: 0.7).count, 1, "near-full stays quiet")
        XCTAssertEqual(RiskWithinField.sentences(field(coverage: 0.9), mean: 0.7).count, 1, "0,9 itself is quiet")
    }

    func testAnEvenFieldSaysOnlyTheShare() {
        XCTAssertEqual(RiskWithinField.sentences(field(share: nil), mean: 0.7), [])
    }

    func testTheAssistantGetsTheFiguresOverTheVisiblePart() {
        XCTAssertEqual(RiskWithinField.facts(field(p10: 0.41, p50: 0.74, p90: 0.88)),
                       "NDVI по видимата част на парцела: P10 0,41, медиана 0,74, P90 0,88; под прага 0,35: 7\(nbsp)%.")
        XCTAssertEqual(RiskWithinField.facts(field(share: nil, coverage: 0.6)),
                       "NDVI по видимата част на парцела: P10 0,60, медиана 0,70, P90 0,80; видими 60\(nbsp)% от парцела.")
        XCTAssertNil(RiskWithinField.facts(field(p10: nil, p50: nil, p90: nil, share: nil)))
    }

    /// Where in the field (#562 stage 2b): the zone in words, geographic.
    func testTheWeakestZoneIsSaidInWords() {
        let nw = ParcelRisk.Weakest(zone: "NW", ndvi: 0.39, delta: -0.14, bounds: nil)
        XCTAssertEqual(RiskWithinField.weakest(nw),
                       "Най-слаба е северозападната част на парцела (NDVI 0,39, с 0,14 под медианата).")
        let centre = ParcelRisk.Weakest(zone: "C", ndvi: 0.5, delta: -0.2, bounds: nil)
        XCTAssertEqual(RiskWithinField.weakest(centre),
                       "Най-слаба е средата на парцела (NDVI 0,50, с 0,20 под медианата).")
        for zone in ["NW", "N", "NE", "W", "C", "E", "SW", "S", "SE"] {
            XCTAssertNotNil(RiskWithinField.weakest(.init(zone: zone, ndvi: 0.4, delta: -0.12, bounds: nil)), zone)
        }
        XCTAssertNil(RiskWithinField.weakest(.init(zone: "NNE", ndvi: 0.4, delta: -0.12, bounds: nil)),
                     "an unknown code costs the sentence")
    }

    /// Decoded from the fixture; absent on a server before #2856.
    func testTheFixtureCarriesItAndOldPayloadsDoNot() async throws {
        func load(_ name: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
        }
        let holes = try await FarmRiskAPI.decodeAnalysis(from: load("risk-analysis-holes"))
        XCTAssertEqual(holes.withinField?.belowThresholdShare, 0.07)
        XCTAssertEqual(holes.withinField?.threshold, 0.35)
        XCTAssertEqual(holes.withinField?.coverage, 0.98)
        XCTAssertEqual(holes.weakest?.zone, "NW")
        XCTAssertEqual(holes.weakest?.bounds?.count, 4)
        let simple = try await FarmRiskAPI.decodeAnalysis(from: load("risk-analysis-simple"))
        XCTAssertNil(simple.withinField)
        XCTAssertNil(simple.weakest, "null or absent: nothing is said")
    }
}
