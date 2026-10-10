import XCTest
@testable import Agrent

/// «Култура» (#245): one crop's costs per decare, over the land it stands on.
/// NOTHING HERE SAVES A COST — the sheet's rules are decided above the wire.
final class CropSheetTests: XCTestCase {

    private let day = "2026-10-10"
    private let wheat = CropChoice(commodity: "wheat", areaDca: Decimal(string: "123.4")!)

    private func row(_ category: CostCategory, in sheet: CropSheet) -> CropSheet.Row {
        sheet.groups.first { $0.category == category }!.rows[0]
    }

    private func set(_ category: CostCategory, _ text: String, name: String = "", in sheet: inout CropSheet) {
        let index = sheet.groups.firstIndex { $0.category == category }!
        sheet.groups[index].rows[0].perDcaText = text
        sheet.groups[index].rows[0].name = name
    }

    private func encoded(_ draft: CreateCostEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    // MARK: - The crops

    /// Only a crop with land is offered, and its decares come from the
    /// number's own digits: 12.34 ha is 123.4 dca, not 123.39999….
    func testOnlyACropWithLandIsOffered() async throws {
        let payload = try await APIClient.shared.decode(fixture("calculator-sample"), as: CalculatorPayload.self)
        let crops = CropChoice.from(payload.rows)
        XCTAssertEqual(crops.map(\.commodity), ["WHEAT", "SUNFLOWER"], "positive control: both have land")
        XCTAssertEqual(crops.first?.areaDca, Decimal(string: "123.4"))
        XCTAssertEqual(CropChoice.decares(hectares: 0.1), Decimal(1))
    }

    func testACropWithNoLandIsNotOffered() throws {
        let rows = try APIClientTestDecoder.decode(CalculatorPayload.self, from: String(
            decoding: fixture("calculator-sample"), as: UTF8.self)
            .replacingOccurrences(of: "\"occupiedAreaHa\": 12.34", with: "\"occupiedAreaHa\": 0")
            .replacingOccurrences(of: "\"occupiedAreaHa\": 4.5", with: "\"occupiedAreaHa\": null")).rows
        XCTAssertEqual(rows.count, 2, "positive control: the rows are still there")
        XCTAssertTrue(CropChoice.from(rows).isEmpty)
    }

    // MARK: - What goes out

    /// Each rate × the crop's land, to the cent; the crop named and no land
    /// linked; the rate kept as typed.
    func testEveryLineIsTheRateOverTheCropsLand() throws {
        var sheet = CropSheet()
        set(.rent, "25,56", in: &sheet)
        set(.pesticide, "7,33", name: "  Хербицид ", in: &sheet)
        let drafts = sheet.drafts(crop: wheat, currency: "EUR", incurredOn: day)
        XCTAssertEqual(drafts.map(\.category), [.rent, .pesticide])
        // 25.56 × 123.4 = 3154.104; 7.33 × 123.4 = 904.522.
        XCTAssertEqual(drafts.map(\.amount), [Decimal(string: "3154.1")!, Decimal(string: "904.52")!])
        XCTAssertEqual(drafts.map(\.amountPerDca), [Decimal(string: "25.56"), Decimal(string: "7.33")])

        let json = try encoded(drafts[1])
        XCTAssertEqual(json["allocationBasis"] as? String, "CROP")
        XCTAssertEqual(json["commodityCanonical"] as? String, "wheat")
        XCTAssertEqual(json["description"] as? String, "Хербицид")
        XCTAssertEqual(json["incurredOn"] as? String, day)
        XCTAssertNil(json["seasonId"], "the server takes the season from the date")
        XCTAssertNil(json["parcelId"], "a crop cost names the crop, not the land")
        XCTAssertNil(json["supplier"])
    }

    /// The fields a crop cost adds are absent from every other draft, so an
    /// overhead's body — and the idempotency key hashed from it — is as it was.
    func testAnOverheadDraftCarriesNoCropFields() throws {
        var overhead = OverheadSheet()
        overhead.credit.amountText = "1000"
        let json = try encoded(overhead.drafts(currency: "EUR", incurredOn: day)[0])
        XCTAssertEqual(json["allocationBasis"] as? String, "HOLDING", "positive control")
        XCTAssertNil(json["commodityCanonical"])
        XCTAssertNil(json["amountPerDca"])
    }

    func testTheTotalsAreWhatTheBooksWillHold() {
        var sheet = CropSheet()
        set(.rent, "25,56", in: &sheet)
        set(.seed, "7,33", in: &sheet)
        XCTAssertEqual(sheet.perDcaSum, Decimal(string: "32.89"))
        // Each line's own cents, added: 3154.10 + 904.52, not 32.89 × 123.4.
        XCTAssertEqual(sheet.totalAmount(areaDca: wheat.areaDca), Decimal(string: "4058.62"))
        XCTAssertNil(CropSheet().totalAmount(areaDca: wheat.areaDca))
    }

    func testRowsAddAndTheLastOneStays() {
        var sheet = CropSheet()
        sheet.addRow(to: .fertilizer)
        XCTAssertEqual(sheet.groups.first { $0.category == .fertilizer }?.rows.count, 2)
        sheet.removeRows(at: [0, 1], from: .fertilizer)
        XCTAssertEqual(sheet.groups.first { $0.category == .fertilizer }?.rows.count, 1)
        // By id, as the VoiceOver action removes one: the other row stays.
        sheet.addRow(to: .pesticide)
        let rows = sheet.groups.first { $0.category == .pesticide }!.rows
        sheet.removeRow(rows[0].id, from: .pesticide)
        XCTAssertEqual(sheet.groups.first { $0.category == .pesticide }?.rows.map(\.id), [rows[1].id])
        XCTAssertTrue(sheet.groups.first { $0.category == .pesticide }!.takesRows)
        XCTAssertFalse(sheet.groups.first { $0.category == .rent }!.takesRows)
    }

    // MARK: - Said before the request

    func testProblemsAreSaidBeforeTheRequest() {
        var sheet = CropSheet()
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [.nothingEntered])
        set(.rent, "двайсет", in: &sheet)
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [.unreadable(.rent)])
        set(.rent, "0", in: &sheet)
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [.notPositive(.rent)])
        set(.rent, "0,001", in: &sheet)
        XCTAssertEqual(sheet.problems(areaDca: 1), [.roundsToNothing(.rent)])
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [], "0.001 × 123.4 is 12 cents")
        set(.rent, "999999999999", in: &sheet)
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [.tooLarge(.rent)])
    }

    /// The batch takes 25 lines (agri-saas #1604); a 26th is said here.
    func testMoreLinesThanOneSheetTakesIsSaid() {
        var sheet = CropSheet()
        let index = sheet.groups.firstIndex { $0.category == .pesticide }!
        sheet.groups[index].rows = (0..<CropSheet.maxLines).map { _ in CropSheet.Row(perDcaText: "1") }
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [], "positive control: 25 is one sheet")
        set(.rent, "1", in: &sheet)
        XCTAssertEqual(sheet.problems(areaDca: wheat.areaDca), [.tooManyLines])
    }

    // MARK: - The farm's last sheet

    func testTheDefaultsDecode() async throws {
        let defaults = try await APIClient.shared.decode(fixture("costs-defaults-crop"), as: CropCostDefaults.self)
        XCTAssertEqual(defaults.commodity, "wheat")
        XCTAssertEqual(defaults.lines.count, 5)
        XCTAssertNil(defaults.lines[4].amountPerDca, "a TOTAL, not an empty line")
        XCTAssertEqual(defaults.lines[2].description, "Хербицид")
    }

    /// Row for row: leva converted and said so, a total kept by name and left
    /// unfilled, plant protection as its two named rows.
    func testThePrefillIsTheLastSheetRowForRow() async throws {
        let defaults = try await APIClient.shared.decode(fixture("costs-defaults-crop"), as: CropCostDefaults.self)
        var sheet = CropSheet()
        sheet.prefill(from: defaults, currency: "EUR")

        let rent = row(.rent, in: sheet)
        XCTAssertEqual(rent.perDcaText, "25,56", "50 лв at 1.95583")
        XCTAssertEqual(rent.convertedFromLeva, 50)
        XCTAssertNotNil(rent.lastEnteredOn)
        XCTAssertEqual(row(.seed, in: sheet).perDcaText, "9,5")
        XCTAssertNil(row(.seed, in: sheet).convertedFromLeva)

        let pesticides = sheet.groups.first { $0.category == .pesticide }!.rows
        XCTAssertEqual(pesticides.map(\.name), ["Хербицид", "Фунгицид"])
        XCTAssertEqual(pesticides.map(\.perDcaText), ["3,2", "2,8"])

        let fertiliser = row(.fertilizer, in: sheet)
        XCTAssertEqual(fertiliser.name, "Амониева селитра")
        XCTAssertEqual(fertiliser.perDcaText, "")
        XCTAssertTrue(fertiliser.lastWasTotal)
        XCTAssertEqual(row(.fuel, in: sheet).perDcaText, "", "no history: left empty, never zero")
    }

    /// A figure typed before the defaults arrived is the farmer's.
    func testATypedGroupIsNotOverwritten() async throws {
        let defaults = try await APIClient.shared.decode(fixture("costs-defaults-crop"), as: CropCostDefaults.self)
        var sheet = CropSheet()
        set(.rent, "30", in: &sheet)
        sheet.prefill(from: defaults, currency: "EUR")
        XCTAssertEqual(row(.rent, in: sheet).perDcaText, "30")
        XCTAssertEqual(row(.seed, in: sheet).perDcaText, "9,5", "positive control: the rest is filled")
    }

    /// A currency the sheet does not convert keeps its row, unfilled and said;
    /// a category the sheet does not list gets its own group; one this build
    /// has never heard of cannot be sent back.
    func testWhatTheSheetCannotTakeIsKeptOrSaid() throws {
        let defaults = try APIClientTestDecoder.decode(CropCostDefaults.self, from: """
            {"commodity":"wheat","lines":[
              {"category":"FUEL","amountPerDca":2,"currency":"USD","incurredOn":"2025-10-01T00:00:00.000Z","description":null},
              {"category":"OTHER","amountPerDca":4,"currency":"EUR","incurredOn":"2025-10-01T00:00:00.000Z","description":"Застраховка"},
              {"category":"IRRIGATION","amountPerDca":5,"currency":"EUR","incurredOn":"2025-10-01T00:00:00.000Z","description":null}
            ]}
            """)
        var sheet = CropSheet()
        sheet.prefill(from: defaults, currency: "EUR")
        let fuel = row(.fuel, in: sheet)
        XCTAssertEqual(fuel.perDcaText, "")
        XCTAssertEqual(fuel.unconvertedCurrency, "USD")
        XCTAssertEqual(sheet.groups.last?.category, .other)
        XCTAssertEqual(sheet.groups.last?.rows.first?.perDcaText, "4")
        XCTAssertEqual(sheet.groups.count, CropSheet.categories.count + 1, "IRRIGATION is not a group")
    }
}
