import XCTest
@testable import Agrent

/// «Общи» (#245): a year's overheads, each spread over the whole farm.
/// NOTHING HERE SAVES A COST — the sheet's rules are decided above the wire.
final class OverheadSheetTests: XCTestCase {

    private let day = "2026-10-09"

    private func defaults(_ json: String) throws -> OverheadDefaults {
        try APIClientTestDecoder.decode(OverheadDefaults.self, from: json)
    }

    private func encoded(_ draft: CreateCostEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    }

    // MARK: - What goes out

    /// Every line the whole farm's, by area — the owner's «per dca of the
    /// whole farm, not only over a given crop decares».
    func testEveryLineSpreadsOverTheWholeFarm() throws {
        var sheet = OverheadSheet()
        sheet.payroll.amountText = "36 000"
        sheet.credit.amountText = "1250,50"
        sheet.other.amountText = "800"
        sheet.otherNote = "  Абонаменти  "
        let drafts = sheet.drafts(currency: "BGN", incurredOn: day)
        XCTAssertEqual(drafts.map(\.category), [.payroll, .credit, .other])
        XCTAssertEqual(drafts.map(\.amount), [36000, Decimal(string: "1250.5")!, 800])
        for draft in drafts { XCTAssertEqual(try encoded(draft)["allocationBasis"] as? String, "HOLDING") }
        XCTAssertEqual(drafts.last?.description, "Абонаменти")
        XCTAssertNil(drafts.first?.description)
    }

    /// People × salary go out beside the total — both or neither, PAYROLL
    /// only — and a total typed as a total carries neither.
    func testThePeopleGoOutOnlyWithTheSalary() throws {
        var sheet = OverheadSheet()
        sheet.payrollMode = .perPerson
        sheet.headcountText = "3"
        sheet.perPersonText = "12000"
        sheet.peopleChanged()
        let perPerson = try encoded(try XCTUnwrap(sheet.drafts(currency: "BGN", incurredOn: day).first))
        XCTAssertEqual(perPerson["amount"] as? Int, 36000)
        XCTAssertEqual(perPerson["payrollHeadcount"] as? Int, 3)
        XCTAssertEqual(perPerson["payrollAnnualPerPerson"] as? Int, 12000)

        sheet.payrollMode = .total
        let total = try encoded(try XCTUnwrap(sheet.drafts(currency: "BGN", incurredOn: day).first))
        XCTAssertNil(total["payrollHeadcount"])
        XCTAssertNil(total["payrollAnnualPerPerson"])
    }

    /// The one-line form's drafts are untouched: none of the new keys, so the
    /// same content mints the same idempotency key it always did.
    func testAOneLineDraftCarriesNoneOfTheNewKeys() throws {
        let draft = CreateCostEntry(category: .fuel, amount: 100, currency: "BGN",
                                    incurredOn: day, supplier: nil, description: nil)
        let body = try encoded(draft)
        for key in ["allocationBasis", "payrollHeadcount", "payrollAnnualPerPerson"] {
            XCTAssertNil(body[key], key)
        }
    }

    // MARK: - The salary's total

    /// The total follows people × salary until the farmer types it — then it
    /// is theirs: a hire who started in May makes a true total that does not
    /// match, and the server takes `amount` as written.
    func testTheTotalFollowsThePeopleUntilTypedOver() {
        var sheet = OverheadSheet()
        sheet.payrollMode = .perPerson
        sheet.headcountText = "3"
        sheet.perPersonText = "12000"
        sheet.peopleChanged()
        XCTAssertEqual(sheet.payroll.amountText, "36000")

        sheet.payroll.amountText = "35500"
        sheet.payrollTotalEdited = true
        sheet.headcountText = "4"
        sheet.peopleChanged()
        XCTAssertEqual(sheet.payroll.amountText, "35500", "the farmer's total was overwritten")
    }

    // MARK: - Prefill

    /// The farm's last values, each with its date; salaries as people × salary
    /// when that is how they were entered; a line with no history EMPTY, never
    /// zero — a zero is a figure nobody typed.
    func testThePrefillIsTheFarmsLastValuesAndNothingElse() throws {
        let last = try defaults(#"""
        {"overheads":[
          {"category":"PAYROLL","amount":36000,"currency":"EUR","incurredOn":"2026-01-15T00:00:00.000Z",
           "payrollHeadcount":3,"payrollAnnualPerPerson":12000},
          {"category":"OTHER","amount":4200.5,"currency":"EUR","incurredOn":"2026-02-01T00:00:00.000Z",
           "payrollHeadcount":null,"payrollAnnualPerPerson":null}]}
        """#)
        var sheet = OverheadSheet()
        sheet.prefill(from: last, currency: "EUR")
        XCTAssertEqual(sheet.payrollMode, .perPerson)
        XCTAssertEqual(sheet.headcountText, "3")
        XCTAssertEqual(sheet.perPersonText, "12000")
        XCTAssertEqual(sheet.payroll.amountText, "36000")
        XCTAssertFalse(sheet.payrollTotalEdited, "a total that matches the product still follows it")
        XCTAssertNotNil(sheet.payroll.lastEnteredOn)
        XCTAssertEqual(sheet.other.amountText, "4200,5")
        XCTAssertEqual(sheet.credit.amountText, "", "no history is empty, not zero")
        XCTAssertEqual(sheet.depreciation.amountText, "")
        XCTAssertNil(sheet.payroll.convertedFromLeva, "a figure already in the sheet's currency is as entered")
    }

    /// Costs default to EUR (owner, 2026-10-10). A leva figure from the farm's
    /// history comes in at the changeover's fixed rate and says so; one in a
    /// currency with no fixed rate is left out, never prefilled as euros.
    func testLevaArePrefilledAsEurosAtTheFixedRate() throws {
        let last = try defaults(#"""
        {"overheads":[
          {"category":"PAYROLL","amount":36000,"currency":"BGN","incurredOn":"2025-12-15T00:00:00.000Z",
           "payrollHeadcount":3,"payrollAnnualPerPerson":12000},
          {"category":"CREDIT","amount":24000,"currency":"BGN","incurredOn":"2025-11-01T00:00:00.000Z",
           "payrollHeadcount":null,"payrollAnnualPerPerson":null},
          {"category":"OTHER","amount":900,"currency":"USD","incurredOn":"2026-02-01T00:00:00.000Z",
           "payrollHeadcount":null,"payrollAnnualPerPerson":null}]}
        """#)
        var sheet = OverheadSheet()
        sheet.prefill(from: last, currency: "EUR")
        XCTAssertEqual(sheet.payroll.amountText, "18406,51")
        XCTAssertEqual(sheet.perPersonText, "6135,5")
        XCTAssertEqual(sheet.payroll.convertedFromLeva, 36000)
        // 3 × 6135,50 is not 18406,51 to the cent; that is rounding, not the
        // farmer typing over the product, so the total still follows it.
        XCTAssertFalse(sheet.payrollTotalEdited)
        XCTAssertEqual(sheet.credit.amountText, "12271,01")
        XCTAssertEqual(sheet.other.amountText, "", "no fixed rate for USD: left out, not prefilled as euros")
        XCTAssertEqual(OverheadFields.convertedNote(24000),
                       "Превалутирано от 24\u{00A0}000,00 лв. по фиксирания курс 1,95583 лв. за 1 €.")
    }

    func testTheFixedRateIsExactAndOnlyForLevaToEuro() {
        XCTAssertEqual(EuroChangeover.convert(Decimal(string: "1.95583")!, from: "BGN", to: "EUR"), 1)
        XCTAssertEqual(EuroChangeover.convert(100, from: "eur", to: "EUR"), 100)
        XCTAssertNil(EuroChangeover.convert(100, from: "EUR", to: "BGN"), "the sheet never converts back into leva")
        XCTAssertNil(EuroChangeover.convert(100, from: "USD", to: "EUR"))
    }

    /// A total that did not match its people was the farmer's — prefilled as
    /// theirs, so editing the people does not overwrite it.
    func testAPrefilledMismatchStaysTheFarmers() throws {
        let last = try defaults(#"""
        {"overheads":[{"category":"PAYROLL","amount":35500,"currency":"BGN",
          "incurredOn":"2026-01-15T00:00:00.000Z","payrollHeadcount":3,"payrollAnnualPerPerson":12000}]}
        """#)
        var sheet = OverheadSheet()
        sheet.prefill(from: last, currency: "BGN")
        XCTAssertTrue(sheet.payrollTotalEdited)
    }

    /// The defaults arrive after the sheet opens: a figure typed meanwhile
    /// is not overwritten.
    func testThePrefillLeavesWhatWasTyped() throws {
        let last = try defaults(#"""
        {"overheads":[{"category":"OTHER","amount":4200,"currency":"BGN",
          "incurredOn":"2026-02-01T00:00:00.000Z","payrollHeadcount":null,"payrollAnnualPerPerson":null}]}
        """#)
        var sheet = OverheadSheet()
        sheet.other.amountText = "999"
        sheet.prefill(from: last, currency: "BGN")
        XCTAssertEqual(sheet.other.amountText, "999")
    }

    /// The register's figure goes into an empty «Амортизация», and over a
    /// figure only when asked («Използвай»).
    func testTheRegistersFigureFillsOnlyAnEmptyField() {
        var sheet = OverheadSheet()
        sheet.useRegister(15000, onlyIfEmpty: true)
        XCTAssertEqual(sheet.depreciation.amountText, "15000")
        sheet.depreciation.amountText = "14000"
        sheet.useRegister(15000, onlyIfEmpty: true)
        XCTAssertEqual(sheet.depreciation.amountText, "14000")
        sheet.useRegister(15000, onlyIfEmpty: false)
        XCTAssertEqual(sheet.depreciation.amountText, "15000")
    }

    // MARK: - Problems

    func testTheProblemsAreSaidBeforeTheRequest() {
        XCTAssertEqual(OverheadSheet().problems, [.nothingEntered])

        var sheet = OverheadSheet()
        sheet.credit.amountText = "сто"
        XCTAssertEqual(sheet.problems, [.unreadable(.credit)])

        sheet.credit.amountText = "0"
        XCTAssertEqual(sheet.problems, [.notPositive(.credit)])

        // Per person with one of the two: the server takes both or neither.
        sheet = OverheadSheet()
        sheet.payrollMode = .perPerson
        sheet.headcountText = "3"
        sheet.payroll.amountText = "36000"
        XCTAssertEqual(sheet.problems, [.peopleIncomplete])
        sheet.perPersonText = "12000"
        XCTAssertEqual(sheet.problems, [], "positive control")
    }
}

/// The machine register's figure, and what it leaves out — each a number
/// that would look authoritative and be wrong if missed (agri-saas #1506).
final class MachineryDepreciationTests: XCTestCase {

    private func register(_ json: String) throws -> MachineryDepreciation {
        try APIClientTestDecoder.decode(MachineryDepreciation.self, from: json)
    }

    private func body(method: String = "STRAIGHT_LINE", total: Int = 15000,
                      unallocated: Int = 0, truncated: Bool = false) -> String {
        let rows = (0..<unallocated).map {
            #"{"assetId":"a\#($0)","assetKey":null,"assetName":"М\#($0)","purchaseCost":40000,"reason":"NO_USEFUL_LIFE"}"#
        }.joined(separator: ",")
        return #"{"method":"\#(method)","charges":[],"totalAnnualCharge":\#(total),"unallocated":[\#(rows)],"#
            + #""unallocatedCost":\#(unallocated * 40000),"truncated":\#(truncated)}"#
    }

    /// `NONE` is «not computed», not zero: nothing is offered.
    func testNoneOffersNothingAndSaysWhy() throws {
        let none = try register(body(method: "NONE", total: 0))
        XCTAssertNil(none.offered)
        XCTAssertEqual(none.caveats, ["Регистърът на техниката не изчислява амортизация."])
    }

    func testTheOfferAndWhatItLeavesOut() throws {
        let complete = try register(body())
        XCTAssertEqual(complete.offered, 15000)
        XCTAssertEqual(complete.caveats, [], "positive control: nothing left out")

        XCTAssertEqual(try register(body(unallocated: 1)).caveats,
                       ["1 машина без срок на ползване не е включена — сумата е занижена."])
        XCTAssertEqual(try register(body(unallocated: 2)).caveats,
                       ["2 машини без срок на ползване не са включени — сумата е занижена."])
        XCTAssertEqual(try register(body(truncated: true)).caveats,
                       ["Регистърът е съкратен — сумата е частична."])
    }

    /// `reason` is a growing union: an unknown one still decodes.
    func testAnUnknownReasonStillDecodes() throws {
        let json = #"{"method":"STRAIGHT_LINE","charges":[],"totalAnnualCharge":0,"unallocated":[{"assetId":"a","assetKey":null,"assetName":"М","purchaseCost":1,"reason":"SOMETHING_NEW"}],"unallocatedCost":1,"truncated":false}"#
        XCTAssertEqual(try register(json).unallocated.first?.reason, "SOMETHING_NEW")
    }
}
