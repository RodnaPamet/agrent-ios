import XCTest
@testable import Agrent

/// Turns `Tests/Fixtures/calculator-sample.json` from a one-off reference into
/// a regression gate.
///
/// It is the only evidence that exists for this payload: production returns an
/// empty one (the tenant has zero Seasons, Plantings and CropPlans), so no row,
/// and no element type inside a row, is observable on the wire.
///
/// Decoding goes through `APIClient.decode` rather than a fresh `JSONDecoder`,
/// deliberately. The app's decoder carries a custom ISO 8601 date strategy, and
/// a fresh decoder would not — so a plain-decoder test would pass while the app
/// failed, which is the opposite of useful.
final class CalculatorPayloadTests: XCTestCase {

    private func loadFixture() throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "calculator-sample", withExtension: "json")
            ?? bundle.url(forResource: "Fixtures/calculator-sample", withExtension: "json")
        else {
            XCTFail("calculator-sample.json missing from the test bundle")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func decoded() async throws -> CalculatorPayload {
        try await APIClient.shared.decode(loadFixture(), as: CalculatorPayload.self)
    }

    func testPayloadDecodes() async throws {
        let payload = try await decoded()
        XCTAssertEqual(payload.rows.count, 2)
        XCTAssertEqual(payload.seasonId, "season_2026")
        XCTAssertFalse(payload.truncated)
    }

    // MARK: - Trap 1: two date spellings, neither a Date

    /// If either of these is ever typed as `Date`, the app's decoder rejects
    /// it and the WHOLE payload fails — not just the field. `priceObservedAt`
    /// is the dangerous one: yyyy-mm-dd is not ISO 8601 date-time in any
    /// spelling the decoder accepts.
    func testBothDateFieldsStayStrings() async throws {
        let payload = try await decoded()
        XCTAssertEqual(payload.generatedAt, "2026-09-21T15:04:09.618Z")
        XCTAssertEqual(payload.rows[0].priceObservedAt, "2026-09-18")
        XCTAssertNil(payload.rows[1].priceObservedAt)
    }

    // MARK: - Trap 2: areaDca comes from the payload

    /// The web recomputes this with an UNROUNDED `haToDca` while the payload
    /// rounds to 2dp, so the two disagree. Every per-dca figure was computed
    /// against the payload's value, so anything shown beside them must use it.
    ///
    /// Row 1 of the fixture proves the point by accident: its
    /// `standingCropAreaHa` is 12.34 (= 123.4 dca) while its `areaDca` is 45.
    /// Recomputing would put 123.4 on screen next to costs derived from 45.
    func testAreaDcaIsReadNotRecomputed() async throws {
        let payload = try await decoded()
        XCTAssertEqual(payload.rows[0].perArea.areaDca, 123.4)
        XCTAssertEqual(payload.rows[1].perArea.areaDca, 45)
        XCTAssertNotEqual(
            payload.rows[1].perArea.areaDca,
            payload.rows[1].standingCropAreaHa * 10,
            "recomputing areaDca diverges from the payload — use the payload's"
        )
    }

    // MARK: - Uncertainty: two casings, and an unknown that must not be fatal

    func testUncertaintyDecodesBothCasings() async throws {
        let payload = try await decoded()
        let exact = payload.rows[0], refused = payload.rows[1]
        XCTAssertEqual(exact.netUncertainty, .exact)          // "exact"
        XCTAssertEqual(exact.costUncertainty, .allocated)     // "allocated"
        XCTAssertEqual(exact.perArea.uncertainty, .exact)     // "EXACT"
        XCTAssertEqual(exact.breakEven.uncertainty, .exact)   // "EXACT"

        XCTAssertEqual(refused.netUncertainty, .refused)      // "refused"
        XCTAssertEqual(refused.costUncertainty, .atLeast)     // "atLeast"
        XCTAssertEqual(refused.perArea.uncertainty, .refused) // "REFUSED"
    }

    /// The `LogEntryType` lesson applied: an uncertainty level the app has
    /// never heard of costs a vague label on one figure, not the screen.
    func testUnknownUncertaintyDegradesInsteadOfThrowing() throws {
        let json = Data("\"SOMETHING_NEW\"".utf8)
        let value = try JSONDecoder().decode(Uncertainty.self, from: json)
        XCTAssertEqual(value, .unknown)
    }

    // MARK: - The refused row reaches what the exact row cannot

    func testRefusedRowCarriesReasonAndNilFigures() async throws {
        let row = try await decoded().rows[1]
        XCTAssertNil(row.netWorth)
        XCTAssertNil(row.pricePerTonne)
        XCTAssertEqual(row.netWorthUnavailableReason, "No market price for SUNFLOWER")
        XCTAssertTrue(row.showProduceRent)
        XCTAssertTrue(row.rentCurrencyUnknown)
        XCTAssertNil(row.breakEven.breakEvenPricePerTonne)
        XCTAssertEqual(row.perArea.refusalCode, "NO_STANDING_CROP_VALUE")
    }

    func testExactRowCarriesFigures() async throws {
        let row = try await decoded().rows[0]
        XCTAssertEqual(row.netWorth, 26554)
        XCTAssertEqual(row.costBreakdown.count, 3)
        XCTAssertEqual(row.costCurrencyCodes, ["BGN"])
        XCTAssertEqual(row.expectedTonnes, 61.7, accuracy: 0.001)
    }

    // MARK: - Containers

    func testFarmAndExclusions() async throws {
        let payload = try await decoded()
        XCTAssertEqual(payload.farm.totals.first?.currency, "BGN")
        XCTAssertEqual(payload.farm.totals.first?.refusedCommodities, ["SUNFLOWER"])
        XCTAssertEqual(payload.exclusions.commoditiesWithNoPrice.first?.id, "SUNFLOWER")
        XCTAssertEqual(payload.exclusions.all.count, 2)
        XCTAssertFalse(payload.exclusions.isEmpty)
        XCTAssertEqual(payload.unvalued.noUnitCost, 2)
        XCTAssertFalse(payload.unvalued.isClean)
        XCTAssertEqual(payload.cashOut.first?.categories, ["SEED", "FUEL"])
        XCTAssertEqual(payload.unallocatedToCrop.parcelIds, ["pa_7"])
        XCTAssertEqual(payload.imputedLandCharge.perHa, 480)
    }

    /// A malformed element in a footnote list must not take the calculator
    /// down with it — seven of the nine exclusion arrays have never been
    /// observed with anything in them.
    func testMalformedExclusionElementIsDroppedNotFatal() throws {
        let json = Data("""
        {"plantingsMissingYieldEstimate":[{"id":"ok","label":"fine"},{"nope":1}],
         "plantingsUnknownCommodity":[],"lotsUnresolvedUnit":[],
         "lotsUnknownCommodity":[],"commoditiesWithNoPrice":[],
         "leasesUnresolvedRent":[],"leasesUnattributed":[],
         "leasesProduceRentUnpriced":[],"payrollUnattributable":[]}
        """.utf8)
        let exclusions = try JSONDecoder().decode(Exclusions.self, from: json)
        XCTAssertEqual(exclusions.plantingsMissingYieldEstimate.count, 1)
        XCTAssertEqual(exclusions.plantingsMissingYieldEstimate.first?.id, "ok")
    }

    /// The empty payload production actually returns must decode too.
    func testProductionEmptyPayloadDecodes() async throws {
        let json = Data("""
        {"generatedAt":"2026-09-21T15:04:09.618Z","seasonId":null,"rows":[],
         "farm":{"totals":[],"refusedWithoutCurrency":[]},
         "exclusions":{"plantingsMissingYieldEstimate":[],"plantingsUnknownCommodity":[],
          "lotsUnresolvedUnit":[],"lotsUnknownCommodity":[],"commoditiesWithNoPrice":[],
          "leasesUnresolvedRent":[],"leasesUnattributed":[],"leasesProduceRentUnpriced":[],
          "payrollUnattributable":[]},
         "unvalued":{"noUnitCost":0,"unitMismatch":0},"cashOut":[],
         "unallocatedToCrop":{"amount":0,"areaHa":0,"parcelIds":[],"currencies":[]},
         "imputedLandCharge":{"perHa":null,"areaHa":0,"totalAmount":0,"refusalCode":null},
         "truncated":false}
        """.utf8)
        let payload = try await APIClient.shared.decode(json, as: CalculatorPayload.self)
        XCTAssertTrue(payload.rows.isEmpty)
        XCTAssertNil(payload.seasonId)
        XCTAssertTrue(payload.exclusions.isEmpty)
        XCTAssertTrue(payload.unvalued.isClean)
    }
}
