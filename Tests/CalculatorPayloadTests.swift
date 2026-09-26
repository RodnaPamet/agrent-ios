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
    /// The shipped fixture cannot show this: both its rows divide evenly, so
    /// recomputing from hectares happens to agree. The divergence is
    /// constructed here rather than borrowed from data that does not contain
    /// it.
    ///
    /// An earlier version asserted it using fixture row 1, which had
    /// `standingCropAreaHa` 12.34 against `areaDca` 45. That was a defect in
    /// the fixture's seed, not a rounding difference — the test passed for the
    /// wrong reason and would have kept passing if the rounding had been
    /// removed entirely.
    func testAreaDcaIsReadNotRecomputed() throws {
        // round2(12.3456 * 10) = 123.46, while the web's unrounded haToDca
        // gives 123.456.
        let json = Data("{\"areaDca\":123.46,\"standingValuePerDca\":210,\"attributableCostPerDca\":90.5,\"marginPerDca\":119.5,\"uncertainty\":\"exact\",\"refusalCode\":null}".utf8)
        let perArea = try JSONDecoder().decode(PerArea.self, from: json)

        let areaHa = 12.3456
        XCTAssertEqual(perArea.areaDca, 123.46, "must be the payload's rounded value")
        XCTAssertNotEqual(
            perArea.areaDca, areaHa * 10,
            "recomputing disagrees with the per-dca figures, which used 123.46"
        )
    }

    func testAreaDcaMatchesTheFixture() async throws {
        let payload = try await decoded()
        XCTAssertEqual(payload.rows[0].perArea.areaDca, 123.4)
        XCTAssertEqual(payload.rows[1].perArea.areaDca, 45)
    }

    // MARK: - Uncertainty: two casings, and an unknown that must not be fatal

    /// The server's whole vocabulary, written out literally rather than
    /// derived from `allCases` — a test generated from the thing it checks
    /// cannot detect a change to it. Source: `uncertainty.ts:31-44`.
    func testEveryServerUncertaintyValueDecodes() throws {
        let expected: [(String, Uncertainty)] = [
            ("exact", .exact), ("atLeast", .atLeast), ("atMost", .atMost),
            ("allocated", .allocated), ("partial", .partial), ("refused", .refused),
        ]
        for (raw, value) in expected {
            let data = Data("\"\(raw)\"".utf8)
            let decoded = try JSONDecoder().decode(Uncertainty.self, from: data)
            XCTAssertEqual(decoded, value, "\(raw) decoded to \(decoded)")
        }
    }

    func testUncertaintyOnTheFixture() async throws {
        let payload = try await decoded()
        XCTAssertEqual(payload.rows[0].netUncertainty, .exact)
        XCTAssertEqual(payload.rows[0].costUncertainty, .allocated)
        XCTAssertEqual(payload.rows[0].perArea.uncertainty, .allocated)
        XCTAssertEqual(payload.rows[1].netUncertainty, .refused)
        XCTAssertEqual(payload.rows[1].costUncertainty, .atLeast)
        XCTAssertEqual(payload.rows[1].perArea.uncertainty, .refused)
    }

    /// Case-insensitivity is kept as cheap defence. It is NOT a workaround for
    /// observed behaviour: the earlier claim that the payload mixed casings
    /// was a fixture defect, and the server uses one convention.
    func testCasingToleranceIsDefenceNotWorkaround() throws {
        for raw in ["EXACT", "Exact", "exact"] {
            let data = Data("\"\(raw)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(Uncertainty.self, from: data), .exact)
        }
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
    // MARK: - The slice field the fixture always had

    /// A COST SLICE WITH NO `variant` MUST DECODE.
    ///
    /// `CalculatorCostSlice` requires `id`, `labelKey` and `value` and not
    /// `variant` — it is a colour hint typed `variant?: …`, and `undefined`
    /// does not survive `JSON.stringify`, so the key is absent for any slice
    /// built without one.
    ///
    /// Non-optional, that threw. And `costBreakdown` is an array inside `rows`
    /// inside the payload, so ONE such slice failed the whole calculator —
    /// every cost, every crop, the net worth — on a money screen, over a
    /// colour this app does not render.
    ///
    /// `calculator-sample.json` carries `variant` on all six of its slices, so
    /// the suite had no way to see it. Same as every operation fixture being a
    /// SPRAY, and the milestone test injecting exactly one unknown key.
    func testACostSliceWithoutAVariantDecodes() async throws {
        let slice = try await APIClient.shared.decode(Data(#"""
        {"id":"s1","labelKey":"costRentLabel","value":1234.5}
        """#.utf8), as: CostSlice.self)
        XCTAssertNil(slice.variant)
        XCTAssertEqual(slice.value, 1234.5)

        let coloured = try await APIClient.shared.decode(Data(#"""
        {"id":"s2","labelKey":"costRentLabel","value":1,"variant":"warning"}
        """#.utf8), as: CostSlice.self)
        XCTAssertEqual(coloured.variant, "warning")
    }

    /// And one bare slice inside a whole array does not take the array down —
    /// which is the blast radius, and the only reason this matters.
    func testOneBareSliceDoesNotFailTheArray() async throws {
        let slices = try await APIClient.shared.decode(Data(#"""
        [{"id":"a","labelKey":"costFieldLabel","value":10,"variant":"brand"},
         {"id":"b","labelKey":"costRentLabel","value":20}]
        """#.utf8), as: [CostSlice].self)
        XCTAssertEqual(slices.count, 2)
        XCTAssertNil(slices.last?.variant)
    }

    /// A seventh colour added server-side must not become a decode failure
    /// either. `String?` rather than a six-case enum: the app renders none of
    /// them, so pinning the set would be inventing work that could only break.
    func testAnUnknownVariantIsCarriedRatherThanRefused() async throws {
        let slice = try await APIClient.shared.decode(Data(#"""
        {"id":"s3","labelKey":"x","value":0,"variant":"critical"}
        """#.utf8), as: CostSlice.self)
        XCTAssertEqual(slice.variant, "critical")
    }

}
