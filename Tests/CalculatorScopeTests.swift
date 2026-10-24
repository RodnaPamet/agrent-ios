import XCTest
@testable import Agrent

/// «Всички» or one crop, and «Всички»'s whole-farm block (owner, 2026-10-24).
/// Rows are the fixture's own, reshaped, so they decode exactly as the app's.
@MainActor
final class CalculatorScopeTests: XCTestCase {

    private func fixture() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "calculator-sample", withExtension: "json")
            ?? bundle.url(forResource: "Fixtures/calculator-sample", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func payload(_ rows: [[String: Any]]? = nil) async throws -> CalculatorPayload {
        var json = try fixture()
        if let rows { json["rows"] = rows }
        return try await APIClient.shared.decode(JSONSerialization.data(withJSONObject: json),
                                                 as: CalculatorPayload.self)
    }

    /// The fixture's first row with the figures that matter here replaced.
    private func row(_ commodity: String, area: Double, land: Double? = nil, value: Double?,
                     cost: Double?, margin: Double?, currency: String? = "EUR",
                     costCurrency: String? = nil, uncertainty: String = "exact") throws -> [String: Any] {
        var base = try XCTUnwrap((try fixture()["rows"] as? [[String: Any]])?.first)
        base["commodity"] = commodity
        base["priceCurrency"] = currency ?? NSNull()
        var perArea = try XCTUnwrap(base["perArea"] as? [String: Any])
        perArea["areaDca"] = area
        perArea["costAreaDca"] = land ?? area
        perArea["standingValuePerDca"] = value ?? NSNull()
        perArea["attributableCostPerDca"] = cost ?? NSNull()
        perArea["marginPerDca"] = margin ?? NSNull()
        perArea["costCurrency"] = costCurrency ?? NSNull()
        perArea["uncertainty"] = uncertainty
        base["perArea"] = perArea
        return base
    }

    // MARK: - The farm block

    /// The fixture: wheat with every figure, sunflower with none. Each figure
    /// is wheat's own and names sunflower as left out; the area counts both.
    func testTheFixtureFarm() async throws {
        let figures = FarmFigures(rows: try await payload().rows)
        XCTAssertEqual(figures.areaDca, 168.4, accuracy: 0.0001)
        XCTAssertEqual(figures.value.rates.map(\.perDca), [210])
        XCTAssertEqual(figures.value.rates.first?.currency, "BGN")
        XCTAssertEqual(figures.value.without, ["SUNFLOWER"])
        XCTAssertEqual(figures.cost.rates.first?.perDca ?? 0, 10.13, accuracy: 0.0001)
        XCTAssertNil(figures.cost.rates.first?.currency, "no cost row recorded a currency: shown bare")
        XCTAssertEqual(figures.margin.without, ["SUNFLOWER"])
    }

    /// Weighted, never a plain average: 400 дка at 200 and 100 дка at 100 is
    /// 180 a decare, not 150.
    func testRatesAreWeightedByArea() async throws {
        let rows = try await payload([
            row("WHEAT", area: 400, value: 200, cost: 50, margin: 150),
            row("BARLEY", area: 100, value: 100, cost: 40, margin: 60),
        ]).rows
        let figures = FarmFigures(rows: rows)
        XCTAssertEqual(figures.value.rates.first?.perDca ?? 0, 180, accuracy: 0.0001)
        XCTAssertEqual(figures.cost.rates.first?.perDca ?? 0, 48, accuracy: 0.0001)
        XCTAssertEqual(figures.margin.rates.first?.perDca ?? 0, 132, accuracy: 0.0001)
        XCTAssertEqual(figures.areaDca, 500)
        XCTAssertTrue(figures.value.without.isEmpty)
    }

    /// Cost is per the LAND the crop occupies (#1606), value and margin per
    /// the yield-covered area: each is weighted by its own.
    func testCostWeighsTheLandValueTheForecastArea() async throws {
        let rows = try await payload([
            row("WHEAT", area: 100, land: 300, value: 200, cost: 10, margin: 190),
            row("BARLEY", area: 100, land: 100, value: 100, cost: 30, margin: 70),
        ]).rows
        let figures = FarmFigures(rows: rows)
        XCTAssertEqual(figures.value.rates.first?.perDca ?? 0, 150, accuracy: 0.0001)
        XCTAssertEqual(figures.cost.rates.first?.perDca ?? 0, 15, accuracy: 0.0001, "(10×300 + 30×100) / 400")
        XCTAssertEqual(figures.areaDca, 400, "the land, every crop")
    }

    /// No exchange rate anywhere: two currencies are two lines.
    func testCurrenciesNeverMix() async throws {
        let rows = try await payload([
            row("WHEAT", area: 100, value: 200, cost: nil, margin: nil, currency: "EUR"),
            row("BARLEY", area: 100, value: 300, cost: nil, margin: nil, currency: "BGN"),
        ]).rows
        let rates = FarmFigures(rows: rows).value.rates
        XCTAssertEqual(rates.map(\.currency), ["BGN", "EUR"])
        XCTAssertEqual(rates.map(\.perDca), [300, 200])
    }

    /// One crop's margin is an upper bound, so the farm's is one too.
    func testAnUpperBoundStaysOne() async throws {
        let rows = try await payload([
            row("WHEAT", area: 100, value: 200, cost: 10, margin: 190, uncertainty: "atMost"),
            row("BARLEY", area: 100, value: 100, cost: 30, margin: 70),
        ]).rows
        XCTAssertEqual(FarmFigures(rows: rows).margin.rates.first?.atMost, true)
    }

    /// Sunflower has no market price, so every figure leaves it out: said
    /// once, not under each of four lines.
    func testOneOmissionIsSaidOnce() async throws {
        let payload = try await payload()
        let figures = FarmFigures(rows: payload.rows)
        XCTAssertEqual(FarmFigures.commonOmission(netWorth: payload.farm.totals.map(\.refusedCommodities),
                                                  figures: [figures.value, figures.cost, figures.margin]),
                       ["SUNFLOWER"])
        let mixed = FarmFigures.Figure(rates: [.init(currency: "EUR", perDca: 1, atMost: false)], without: ["BARLEY"])
        XCTAssertNil(FarmFigures.commonOmission(netWorth: [["SUNFLOWER"]], figures: [mixed]),
                     "different crops left out: each figure says its own")
        XCTAssertNil(FarmFigures.commonOmission(netWorth: [[]], figures: []), "nothing left out")
    }

    /// agri-saas #2259: with a crop's cost rate refused (two currencies) the
    /// server still sends a margin computed from the blended sum. It is not
    /// shown on the crop, and not counted in the farm's.
    func testAMarginOverARefusedCostIsNotShown() async throws {
        var refused = try row("WHEAT", area: 100, value: 50, cost: nil, margin: 30)
        var perArea = try XCTUnwrap(refused["perArea"] as? [String: Any])
        perArea["costRefusalCode"] = "COST_CURRENCY_MIXED"
        refused["perArea"] = perArea
        let rows = try await payload([refused, row("BARLEY", area: 100, value: 100, cost: 30, margin: 70)]).rows
        XCTAssertNil(rows[0].perArea.marginText(priceCurrency: rows[0].priceCurrency), "the crop's own line")
        XCTAssertEqual(rows[0].perArea.marginRefusalText(priceCurrency: rows[0].priceCurrency),
                       Self.mixed, "a server before #2272 sends no reason; this one is worked out")
        XCTAssertNil(rows[1].perArea.marginRefusalCode, "a server before #2272 sends none")
        let margin = FarmFigures(rows: rows).margin
        XCTAssertEqual(margin.rates.first?.perDca ?? 0, 70, accuracy: 0.0001, "only barley's")
        XCTAssertEqual(margin.without, ["WHEAT"])
    }

    private static let mixed =
        "Разходите за тази култура са в повече от една валута, затова маржът на декар не се изчислява — изваждането им би го изкривило."
    private static let mismatch =
        "Разходите за тази култура са в различна валута от пазарната цена, затова маржът на декар не се изчислява — не се прилага обменен курс."

    /// agri-saas #2259's other half: the costs in ONE currency, not the
    /// price's. The cost rate stands, since 20 BGN a decare is a good figure;
    /// the margin subtracts it from a value in EUR, so it does not.
    func testAMarginAcrossTwoCurrenciesIsNotShown() async throws {
        let rows = try await payload([
            row("WHEAT", area: 100, value: 50, cost: 20, margin: 30, currency: "EUR", costCurrency: "BGN"),
            row("BARLEY", area: 100, value: 100, cost: 30, margin: 70, currency: "EUR", costCurrency: "EUR"),
        ]).rows
        XCTAssertEqual(rows[0].perArea.costText, Money.text(20, "BGN"), "the cost rate is not refused")
        XCTAssertNil(rows[0].perArea.marginText(priceCurrency: rows[0].priceCurrency))
        XCTAssertEqual(rows[0].perArea.marginRefusalText(priceCurrency: rows[0].priceCurrency), Self.mismatch)
        XCTAssertEqual(rows[1].perArea.marginText(priceCurrency: rows[1].priceCurrency), Num.text(70),
                       "positive control: one currency on both sides")
        XCTAssertNil(rows[1].perArea.marginRefusalText(priceCurrency: rows[1].priceCurrency))
        let margin = FarmFigures(rows: rows).margin
        XCTAssertEqual(margin.rates.map(\.perDca), [70])
        XCTAssertEqual(margin.without, ["WHEAT"])
    }

    /// A cost with no currency is in the farm's own, as net worth assumes.
    /// The journal never writes one, so refusing it would take the margin off
    /// every farm that records its costs there.
    func testACostWithNoCurrencyAgreesWithThePrice() async throws {
        let rows = try await payload([
            row("WHEAT", area: 100, value: 50, cost: 20, margin: 30, currency: "EUR", costCurrency: nil),
        ]).rows
        XCTAssertEqual(rows[0].shownMarginPerDca, 30)
    }

    /// From agri-saas #2272 the server names the reason itself. The value
    /// side's is said once, above, in a sentence that names the margin too.
    func testTheServersMarginReasonIsSaid() async throws {
        func refused(_ commodity: String, _ code: String, value: String? = nil) throws -> [String: Any] {
            var r = try row(commodity, area: 100, value: value == nil ? 50 : nil, cost: nil, margin: nil)
            var perArea = try XCTUnwrap(r["perArea"] as? [String: Any])
            perArea["marginRefusalCode"] = code
            perArea["refusalCode"] = value ?? NSNull()
            r["perArea"] = perArea
            return r
        }
        let rows = try await payload([
            refused("WHEAT", "COST_CURRENCY_MIXED"),
            refused("BARLEY", "NO_STANDING_CROP_VALUE", value: "NO_STANDING_CROP_VALUE"),
            refused("MAIZE", "SOME_FUTURE_CODE"),
        ]).rows
        let said = rows.map { $0.perArea.marginRefusalText(priceCurrency: $0.priceCurrency) }
        XCTAssertEqual(said[0], Self.mixed)
        XCTAssertNil(said[1], "said already by the value side's note")
        XCTAssertTrue(rows[1].perArea.refusalText?.contains("маржът на декар") == true,
                      rows[1].perArea.refusalText ?? "nil")
        XCTAssertEqual(said[2], "Маржът на декар не може да се изчисли.",
                       "a code this build does not know still says something")
        XCTAssertTrue(rows.allSatisfy { $0.shownMarginPerDca == nil })
    }

    // MARK: - The scope

    func testTheScopeRoundTrips() {
        XCTAssertEqual(CalculatorScope(stored: CalculatorScope.all.stored), .all)
        XCTAssertEqual(CalculatorScope(stored: CalculatorScope.crop("WHEAT").stored), .crop("WHEAT"))
        XCTAssertEqual(CalculatorScope(stored: nil), .all, "nothing chosen yet is «Всички»")
    }

    func testAScopeShowsWhatThereIs() async throws {
        let two = try await payload().rows
        XCTAssertEqual(CalculatorScope.crop("WHEAT").resolved(for: two), .crop("WHEAT"))
        XCTAssertEqual(CalculatorScope.crop("MAIZE").resolved(for: two), .all, "a crop no longer grown")
        let one = Array(two.prefix(1))
        XCTAssertEqual(CalculatorScope.all.resolved(for: one), .crop("WHEAT"),
                       "one crop: «Всички» would only repeat it")
    }

    /// Stateful: the choice survives the screen, per farm.
    func testTheChoiceIsRemembered() throws {
        let suite = "calculator-scope-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CalculatorStore(defaults: defaults)
        XCTAssertEqual(first.scope, .all)
        first.choose(.crop("WHEAT"))
        XCTAssertEqual(CalculatorStore(defaults: defaults).scope, .crop("WHEAT"))
        XCTAssertNotEqual(CalculatorStore.key("farm-a"), CalculatorStore.key("farm-b"), "per farm")
    }

    func testTheLabelIsBulgarian() {
        XCTAssertEqual(CalculatorView.scopeLabel(.all), "Всички")
        XCTAssertEqual(CalculatorView.scopeLabel(.crop("WHEAT")), CommodityName.canonical("WHEAT"))
    }
}
