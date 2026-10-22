import XCTest
@testable import Agrent

/// «Продължи»'s check (#362): the amount of product a dose and an area add up
/// to, and the end of the quarantine period. Synthetic doses and areas.
final class TreatmentCheckTests: XCTestCase {
    private func area(decares: Double) -> Area { Area(hectares: decares / 10) }

    /// PRZ's own example: 0,4 л/дка over 176 дка.
    func testTheAmountIsTheDoseTimesTheArea() throws {
        let amount = try XCTUnwrap(TreatmentCheck.amount(dose: Decimal(string: "0.4")!, unitSymbol: "л/дка",
                                                         area: area(decares: 176)))
        XCTAssertEqual(amount.unit, "л")
        XCTAssertEqual(amount.value, 70.4, accuracy: 0.0001)
        XCTAssertEqual(amount.text, "70,4 л")
        XCTAssertEqual(amount.spoken, "70,4 литра")
    }

    /// Bought and measured out in the larger unit once it reaches one.
    func testAThousandOfTheSmallUnitIsTheLargeOne() throws {
        let ml = try XCTUnwrap(TreatmentCheck.amount(dose: 50, unitSymbol: "мл/дка", area: area(decares: 30)))
        XCTAssertEqual(ml.text, "1,5 л")
        let grams = try XCTUnwrap(TreatmentCheck.amount(dose: 25, unitSymbol: "г/дка", area: area(decares: 200)))
        XCTAssertEqual(grams.text, "5 кг")
        XCTAssertEqual(grams.spoken, "5 килограма")
        let small = try XCTUnwrap(TreatmentCheck.amount(dose: 20, unitSymbol: "мл/дка", area: area(decares: 12)))
        XCTAssertEqual(small.text, "240 мл", "under a thousand stays as it was entered")
        XCTAssertEqual(small.spoken, "240 милилитра")
    }

    func testOneIsSpokenInTheSingular() throws {
        let one = try XCTUnwrap(TreatmentCheck.amount(dose: Decimal(string: "0.1")!, unitSymbol: "кг/дка",
                                                      area: area(decares: 10)))
        XCTAssertEqual(one.spoken, "1 килограм")
    }

    /// No unit per area, or no area: no amount, never a guess.
    func testAnAmountThatCantBeWorkedOutIsNone() {
        XCTAssertNil(TreatmentCheck.amount(dose: 2, unitSymbol: "кг", area: area(decares: 10)), "not a rate")
        XCTAssertNil(TreatmentCheck.amount(dose: 2, unitSymbol: "л/т", area: area(decares: 10)), "not per area")
        XCTAssertNil(TreatmentCheck.amount(dose: 2, unitSymbol: "л/дка", area: area(decares: 0)), "no area")
        XCTAssertNil(TreatmentCheck.amount(dose: 2, unitSymbol: "/дка", area: area(decares: 10)), "no quantity")
    }

    /// A rate per hectare multiplies hectares, not decares.
    func testAPerHectareRateUsesHectares() throws {
        let amount = try XCTUnwrap(TreatmentCheck.amount(dose: 2, unitSymbol: "л/ха", area: area(decares: 50)))
        XCTAssertEqual(amount.text, "10 л")
    }

    /// The day plus the period, as the ДНЕВНИК prints it — and the form's
    /// own «Най-ранна дата за прибиране» agrees with the check.
    func testTheEarliestHarvestIsTheDayPlusThePeriod() throws {
        // The calendar the ДНЕВНИК's day arithmetic runs in, here as there.
        let calendar = Calendar(identifier: .gregorian)
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 25)))
        let harvest = try XCTUnwrap(TreatmentCheck.earliestHarvest(after: day, days: 14))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: harvest),
                       DateComponents(year: 2026, month: 6, day: 8))
        var draft = TreatmentDraft(date: day)
        draft.quarantineText = "14"
        XCTAssertEqual(draft.earliestHarvest, harvest)
    }

    /// Why there is no amount, said rather than left blank.
    func testTheScreenSaysWhyThereIsNoAmount() {
        XCTAssertEqual(TreatmentCheckView.noAmount(area: area(decares: 0)),
                       "Нужното количество не се изчислява: избраните парцели са без площ.")
        XCTAssertEqual(TreatmentCheckView.noAmount(area: area(decares: 5)),
                       "Нужното количество не се изчислява: дозата не е на декар.")
        XCTAssertEqual(TreatmentCheckView.withoutAreaNote(0), "")
        XCTAssertTrue(TreatmentCheckView.withoutAreaNote(2).hasPrefix("2 парцела са без площ"))
    }

    /// The website's review step says the same words (agri-saas #2174), and
    /// the owner chose recorded treatments to stay final (2026-10-22).
    func testTheFinalNoteMatchesTheWebsite() {
        XCTAssertEqual(TreatmentCheckView.finalNote,
                       "След записване вписването в ДНЕВНИКА не може да се редактира.")
    }
}
