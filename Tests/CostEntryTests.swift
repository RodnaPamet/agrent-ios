import XCTest
@testable import Agrent

/// A cost is a line on a farm's books, and the grain routes honour NO
/// idempotency — POST twice, with any key or none, and there are two rows.
/// So every guard that can be applied before the request is worth applying.
final class CreateCostEntryTests: XCTestCase {

    private func entry(
        amount: Decimal = 100, currency: String = "BGN",
        incurredOn: String = "2026-09-22"
    ) -> CreateCostEntry {
        CreateCostEntry(
            category: .fuel, amount: amount, currency: currency,
            incurredOn: incurredOn, supplier: nil, description: nil
        )
    }

    // MARK: - Bounds, mirrored from the server

    func testAValidEntryHasNoProblems() {
        XCTAssertTrue(entry().problems.isEmpty)
    }

    /// `amount` is `> 0` on the server, not `>= 0`. A zero-value cost is
    /// refused there, so it is refused here rather than round-tripping.
    func testZeroAndNegativeAmountsAreRefused() {
        XCTAssertEqual(entry(amount: 0).problems, [.amountNotPositive])
        XCTAssertEqual(entry(amount: -1).problems, [.amountNotPositive])
    }

    func testTheUpperBoundMatchesTheServer() {
        XCTAssertTrue(entry(amount: CreateCostEntry.maxAmount).problems.isEmpty)
        XCTAssertEqual(
            entry(amount: CreateCostEntry.maxAmount + 1).problems, [.amountTooLarge])
    }

    func testCurrencyAndDateAreRequired() {
        XCTAssertEqual(entry(currency: "").problems, [.currencyMissing])
        XCTAssertEqual(entry(currency: "   ").problems, [.currencyMissing])
        // min(8) on the server — "2026-9-2" is 8, "2026-9-" is not.
        XCTAssertEqual(entry(incurredOn: "2026-9").problems, [.dateMissing])
    }

    // MARK: - Encoding

    /// `amount` must go out as a JSON NUMBER. The server's schema is
    /// `z.number()`, so a string is rejected — and routing through `Double`
    /// to get a number would reintroduce the binary rounding that
    /// `DecimalString` exists to avoid.
    func testAmountEncodesAsANumberNotAString() throws {
        let json = try String(
            data: JSONEncoder().encode(entry(amount: Decimal(string: "1234.50")!)),
            encoding: .utf8
        )!
        XCTAssertTrue(json.contains("\"amount\":1234.5"), json)
        XCTAssertFalse(json.contains("\"amount\":\""), json)
    }

    /// Exact at a scale binary floating point cannot hold. `0.1 + 0.2` is
    /// the canonical example, and a calculator that disagrees with a farm's
    /// books in the third decimal is one nobody uses twice.
    func testAwkwardAmountsEncodeExactly() throws {
        let json = try String(
            data: JSONEncoder().encode(entry(amount: Decimal(string: "0.07")!)),
            encoding: .utf8
        )!
        XCTAssertTrue(json.contains("\"amount\":0.07"), json)
        XCTAssertFalse(json.contains("0.070000000"), json)
    }

    /// Optional fields are omitted rather than sent as null. The schema
    /// `.strip()`s unknown keys but these are known and nullable, and an
    /// omitted key is the clearer statement of "not provided".
    func testEmptyOptionalsAreOmitted() throws {
        let json = try String(data: JSONEncoder().encode(entry()), encoding: .utf8)!
        XCTAssertFalse(json.contains("supplier"), json)
        XCTAssertFalse(json.contains("description"), json)
    }

    func testTheCategoryGoesOutAsItsServerValue() throws {
        let json = try String(data: JSONEncoder().encode(entry()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"category\":\"FUEL\""), json)
    }
}

final class CostCategoryTests: XCTestCase {

    /// Eight, plus this client's own `unknown` sentinel.
    func testEightCategoriesAreSelectable() {
        XCTAssertEqual(CostCategory.selectable.count, 8)
        XCTAssertFalse(CostCategory.selectable.contains(.unknown))
        XCTAssertEqual(CostCategory.allCases.count, 9)
    }

    func testEveryServerValueDecodes() throws {
        for raw in ["PAYROLL", "RENT", "FERTILIZER", "FUEL",
                    "SEED", "PESTICIDE", "SERVICE", "OTHER"] {
            let c = try JSONDecoder().decode(
                CostCategory.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(c.rawValue, raw)
            XCTAssertNotEqual(c, .unknown)
        }
    }

    /// The GRAIN vocabulary, not the inventory one. `inventory.itemCategory`
    /// spells the same code differently — FERTILIZER is "Тор" there and
    /// "Торове" here — and a screen showing one word where the web shows
    /// another for the same row is worse than either being wrong.
    func testTheGrainVocabularyIsUsedNotTheInventoryOne() {
        XCTAssertEqual(CostCategory.fertilizer.label, "Торове")
        XCTAssertNotEqual(CostCategory.fertilizer.label, "Тор")
    }

    func testEverySelectableCategoryHasABulgarianLabel() {
        for c in CostCategory.selectable {
            XCTAssertNotEqual(c.label, "—", c.rawValue)
            XCTAssertTrue(
                c.label.unicodeScalars.contains { $0.value > 0x400 }, c.label)
        }
    }
}
