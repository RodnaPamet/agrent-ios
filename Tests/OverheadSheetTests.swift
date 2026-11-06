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

    // MARK: - One sheet, one write (#260)

    private func sheet(_ credit: String) -> CostsAPI.Sheet {
        var sheet = OverheadSheet()
        sheet.payroll.amountText = "36 000"
        sheet.credit.amountText = credit
        return CostsAPI.Sheet(lines: sheet.drafts(currency: "EUR", incurredOn: day))
    }

    /// The batch body is `{ lines: [...] }`, each line the single-create
    /// body, in the sheet's order — agri-saas #1604 answers in the order sent.
    func testTheSheetGoesOutAsOneBodyInItsOrder() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sheet("1250"))) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["lines"])
        let lines = try XCTUnwrap(body["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.compactMap { $0["category"] as? String }, ["PAYROLL", "CREDIT"])
        XCTAssertEqual(lines.compactMap { $0["allocationBasis"] as? String }, ["HOLDING", "HOLDING"])
        XCTAssertTrue(CostsAPI.batchPath.hasSuffix("/grain/costs/batch"))
    }

    /// One key for the whole sheet: a retry of the same sheet dedupes, and
    /// correcting any one line makes it a new write.
    func testARetryKeepsTheSheetsKeyAndACorrectedLineDoesNot() {
        let nonce = "6C4E0E84-8F9C-4F8E-9B0A-1D2C3E4F5A6B"
        let key = CostIdempotencyKey.mint(nonce: nonce, draft: sheet("1250"))
        XCTAssertEqual(CostIdempotencyKey.mint(nonce: nonce, draft: sheet("1250")), key)
        XCTAssertNotEqual(CostIdempotencyKey.mint(nonce: nonce, draft: sheet("1251")), key)
        // Another sheet with the same figures is another write.
        XCTAssertNotEqual(CostIdempotencyKey.mint(nonce: UUID().uuidString, draft: sheet("1250")), key)
    }

    /// «Общи» saves through the batch only: a per-line POST is what left a
    /// sheet half-saved.
    func testOverheadsAreSavedAsOneSheet() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Agrent/Calculator/NewCostView.swift"), encoding: .utf8)
        // Both sides save through the one function, «Общи» and «Култура».
        let save = try XCTUnwrap(source.range(of: "private func saveSheet()"))
        let body = String(source[save.upperBound...])
        XCTAssertTrue(body.contains("overhead.drafts("), "positive control: «Общи» goes through the sheet save")
        XCTAssertTrue(body.contains("CostsAPI.createSheet("), "positive control: the sheet is sent whole")
        XCTAssertFalse(source.contains("CostsAPI.create("), "a sheet went back to one POST per line")
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
    }

    /// EUR only, and nothing converted (owner, 2026-11-06: "any trace of
    /// conversion is uprooted"). A leva or dollar figure from the farm's
    /// history is not prefilled and not mentioned: the field is as empty as
    /// for a farm with no history.
    func testOnlyEuroFiguresArePrefilledAndNothingIsConverted() throws {
        let last = try defaults(#"""
        {"overheads":[
          {"category":"PAYROLL","amount":36000,"currency":"BGN","incurredOn":"2025-12-15T00:00:00.000Z",
           "payrollHeadcount":3,"payrollAnnualPerPerson":12000},
          {"category":"CREDIT","amount":24000,"currency":"BGN","incurredOn":"2025-11-01T00:00:00.000Z",
           "payrollHeadcount":null,"payrollAnnualPerPerson":null},
          {"category":"OTHER","amount":900,"currency":"USD","incurredOn":"2026-02-01T00:00:00.000Z",
           "payrollHeadcount":null,"payrollAnnualPerPerson":null},
          {"category":"DEPRECIATION","amount":1500,"currency":"eur","incurredOn":"2026-02-01T00:00:00.000Z",
           "payrollHeadcount":null,"payrollAnnualPerPerson":null}]}
        """#)
        var sheet = OverheadSheet()
        sheet.prefill(from: last, currency: "EUR")
        XCTAssertEqual(sheet.payroll.amountText, "")
        XCTAssertNil(sheet.payroll.lastEnteredOn, "not «Последно въведено» for a figure not shown")
        XCTAssertEqual(sheet.headcountText, "")
        XCTAssertEqual(sheet.credit.amountText, "")
        XCTAssertEqual(sheet.other.amountText, "")
        XCTAssertEqual(sheet.depreciation.amountText, "1500", "positive control: a euro figure is prefilled")
    }

    /// No conversion is left in the app's source: no rate, no «Превалутирано».
    func testNoConversionIsLeftInTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("Agrent"), includingPropertiesForKeys: nil))
        var files = 0
        for case let url as URL in sources where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for trace in ["1,95583", "1.95583", "Превалутира", "превалутира", "EuroChangeover", "фиксирания курс",
                          "конвертиране", "обменен курс"] {
                XCTAssertFalse(text.contains(trace), "\(url.lastPathComponent) still has «\(trace)»")
            }
        }
        XCTAssertGreaterThan(files, 50, "positive control: the sources were found")
    }

    /// A total that did not match its people was the farmer's — prefilled as
    /// theirs, so editing the people does not overwrite it.
    func testAPrefilledMismatchStaysTheFarmers() throws {
        let last = try defaults(#"""
        {"overheads":[{"category":"PAYROLL","amount":35500,"currency":"EUR",
          "incurredOn":"2026-01-15T00:00:00.000Z","payrollHeadcount":3,"payrollAnnualPerPerson":12000}]}
        """#)
        var sheet = OverheadSheet()
        sheet.prefill(from: last, currency: "EUR")
        XCTAssertTrue(sheet.payrollTotalEdited)
    }

    /// The defaults arrive after the sheet opens: a figure typed meanwhile
    /// is not overwritten.
    func testThePrefillLeavesWhatWasTyped() throws {
        let last = try defaults(#"""
        {"overheads":[{"category":"OTHER","amount":4200,"currency":"EUR",
          "incurredOn":"2026-02-01T00:00:00.000Z","payrollHeadcount":null,"payrollAnnualPerPerson":null}]}
        """#)
        var sheet = OverheadSheet()
        sheet.other.amountText = "999"
        sheet.prefill(from: last, currency: "EUR")
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
