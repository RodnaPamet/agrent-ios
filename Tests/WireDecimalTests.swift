import XCTest
@testable import Agrent

/// Every money and tonnage field on the grain routes is `z.number()` going
/// IN and a Prisma `Decimal` column coming OUT, with no DTO between — so the
/// app sends numbers and receives strings on the same field.
///
/// And the string is not presentation-ready. Measured server-side:
/// `new Prisma.Decimal('1234.50')` serialises to `"1234.5"`.
final class WireDecimalTests: XCTestCase {

    private func decode(_ json: String) throws -> WireDecimal {
        try JSONDecoder().decode(WireDecimal.self, from: Data(json.utf8))
    }

    // MARK: - The measured shape

    func testAStringDecimalDecodes() throws {
        XCTAssertEqual(try decode(#""1234.5""#).value, Decimal(string: "1234.5"))
    }

    /// THE test. The server drops the trailing zero, so a cost of 1234.50
    /// arrives as "1234.5" and must come back out at the column's scale.
    /// Rendering the string through would show `1234,5` where the books say
    /// `1234,50`.
    func testTheDroppedTrailingZeroIsRestoredAtTheColumnScale() throws {
        // Asserted on the FRACTION, not the whole rendered string. The
        // grouping separator is the locale's business — bg_BG does not group
        // four digits at all, and where it does group it uses a
        // non-breaking space rather than an ASCII one. Pinning the glyph
        // tests CLDR rather than this type, and it is the third time today
        // a test of mine has hard-coded a rendering it does not own.
        XCTAssertTrue(try decode(#""1234.5""#).text(scale: 2).hasSuffix(",50"))
        XCTAssertTrue(try decode(#""1234""#).text(scale: 2).hasSuffix(",00"))
        XCTAssertTrue(try decode(#""0.5""#).text(scale: 3).hasSuffix(",500"))
        XCTAssertEqual(try decode(#""0.5""#).text(scale: 3), "0,500")
    }

    /// Bulgarian formatting, declared — a comma decimal separator, whatever
    /// the device's locale is. `en_BG` is what this phone reports.
    func testFormattingIsBulgarianNotTheDeviceDefault() throws {
        let text = try decode(#""1234.5""#).text(scale: 2)
        XCTAssertTrue(text.contains(","), text)
        XCTAssertFalse(text.hasSuffix(".50"), text)
    }

    /// Each column has its own scale and they are not interchangeable.
    func testEachColumnScaleIsHonoured() throws {
        let d = try decode(#""12.3""#)
        XCTAssertEqual(d.text(scale: 2), "12,30")   // amount        Decimal(14,2)
        XCTAssertEqual(d.text(scale: 3), "12,300")  // grossTonnes   Decimal(14,3)
        XCTAssertEqual(d.text(scale: 4), "12,3000") // areaHa        Decimal(12,4)
    }

    // MARK: - Precision

    /// The reason this is `Decimal` and not `Double`. A calculator that
    /// disagrees with a farm's books in the third decimal is one nobody
    /// uses twice.
    func testValuesThatBinaryFloatingPointCannotHold() throws {
        XCTAssertEqual(try decode(#""0.1""#).value + (try decode(#""0.2""#).value),
                       Decimal(string: "0.3"))
        // Digits and fraction, not the separator between the groups.
        let big = try decode(#""1234567890.12""#).text(scale: 2)
        XCTAssertTrue(big.hasSuffix(",12"), big)
        XCTAssertEqual(big.filter(\.isNumber), "123456789012", big)
    }

    /// A value already at full scale is unchanged, not re-rounded.
    func testAFullScaleValueIsUntouched() throws {
        XCTAssertEqual(try decode(#""99.99""#).text(scale: 2), "99,99")
    }

    // MARK: - Wire tolerance

    /// The wire uses `.` whatever the device does. Parsing with
    /// `Locale.current` would read "1234.5" as 12345 where `.` groups —
    /// a factor of ten, on money.
    func testTheWireSeparatorIsNotTheDeviceSeparator() throws {
        XCTAssertEqual(try decode(#""1234.5""#).value, Decimal(string: "1234.5"))
        XCTAssertNotEqual(try decode(#""1234.5""#).value, Decimal(12345))
    }

    /// A bare number is accepted too: the same field is `z.number()` going
    /// in, so a route echoing a create back before it round-trips the
    /// database would hand back what it was given. Failing a whole payload
    /// over a field the app can read is the wrong trade.
    func testANumberIsAcceptedAsWell() throws {
        XCTAssertEqual(try decode("1234.5").value, Decimal(string: "1234.5"))
        XCTAssertEqual(try decode("0").value, Decimal(0))
    }

    func testNegativeAndZeroSurvive() throws {
        XCTAssertEqual(try decode(#""-42.75""#).text(scale: 2), "-42,75")
        XCTAssertEqual(try decode(#""0""#).text(scale: 2), "0,00")
    }

    /// Nonsense is a decode failure, not a silent zero. A cost that reads
    /// 0,00 because its amount could not be parsed is worse than a screen
    /// that says it could not load.
    func testUnparseableIsAFailureNotAZero() {
        XCTAssertThrowsError(try decode(#""abc""#))
        XCTAssertThrowsError(try decode(#""""#))
    }

    /// The raw digits are kept for diagnosis but must not be what is shown.
    func testRawIsPreservedForDiagnosisOnly() throws {
        XCTAssertEqual(try decode(#""1234.5""#).raw, "1234.5")
    }
}
