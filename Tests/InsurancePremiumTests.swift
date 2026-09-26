import XCTest
@testable import Agrent

/// Parity with the server's premium engine, against the three cases it
/// publishes as its own agreement tests.
///
/// ── Why these three and not three of my own ──
///
/// `POST /insurance/leads` carries no price and the server recomputes from the
/// four inputs; its figure is what gets stored and emailed. So a local preview
/// is only worth showing if it agrees, and the only way to know it agrees —
/// without firing a POST at the owner's live tenant, which this repo never
/// does — is to compute the cases the server tests itself against.
///
/// They are `tests/unit/insurance/client-server-agreement.test.ts` on
/// agri-saas main. C is the one that matters: it lands exactly on a half-cent
/// and leaves two leftover cents, so it separates round-half-up from
/// truncation AND settles which instalment absorbs the remainder. A `Double`
/// implementation passes A and B and fails C.
final class InsurancePremiumParityTests: XCTestCase {

    /// A — 1000 dca, «100 000», 3 instalments.
    /// EUR 10,000.00 · 10.00/dca · 3,333.34 + 3,333.33 + 3,333.33
    func testReferenceCaseA() throws {
        let sum = try XCTUnwrap(InsurancePremium.moneyCents("100 000"))
        XCTAssertEqual(sum, 10_000_000)

        let q = try XCTUnwrap(InsurancePremium.quote(sumInsuredCents: sum, instalments: 3))
        XCTAssertEqual(q.premiumCents, 1_000_000)
        XCTAssertEqual(q.instalmentsCents, [333_334, 333_333, 333_333])
        XCTAssertEqual(q.perDecareCents(areaDca: 1000), 1_000)
    }

    /// B — «12,345» dca, «3 000», 2 instalments.
    /// EUR 300.00 · 24.30/dca · 150.00 + 150.00
    ///
    /// Both parsers in one case, pulling opposite ways: «12,345» is an AREA so
    /// the comma is decimal, and «3 000» is MONEY so the space is thousands.
    func testReferenceCaseB() throws {
        let area = try XCTUnwrap(InsurancePremium.areaDecares("12,345"))
        XCTAssertEqual(area, 12.345, accuracy: 0.0000001)

        let sum = try XCTUnwrap(InsurancePremium.moneyCents("3 000"))
        XCTAssertEqual(sum, 300_000)

        let q = try XCTUnwrap(InsurancePremium.quote(sumInsuredCents: sum, instalments: 2))
        XCTAssertEqual(q.premiumCents, 30_000)
        XCTAssertEqual(q.instalmentsCents, [15_000, 15_000])
        XCTAssertEqual(q.perDecareCents(areaDca: area), 2_430)
    }

    /// C — 250 dca, «37 500,55», 4 instalments.
    /// EUR 3,750.06 · 15.00/dca · 937.53 + 937.51 × 3
    ///
    /// THE ONE WORTH HAVING. 3 750 055 × 1000 = 3 750 055 000, and the
    /// half-cent is exact: with `+ 5_000` before the divide it rounds UP to
    /// 375 006, and truncation would give 375 005. Then 375 006 / 4 leaves two
    /// cents over, which go to the FIRST instalment.
    func testReferenceCaseC() throws {
        let sum = try XCTUnwrap(InsurancePremium.moneyCents("37 500,55"))
        XCTAssertEqual(sum, 3_750_055)

        let q = try XCTUnwrap(InsurancePremium.quote(sumInsuredCents: sum, instalments: 4))
        XCTAssertEqual(q.premiumCents, 375_006)
        XCTAssertEqual(q.instalmentsCents, [93_753, 93_751, 93_751, 93_751])
        XCTAssertEqual(q.perDecareCents(areaDca: 250), 1_500)
    }

    /// The property behind case C, asserted on its own so it survives a
    /// refactor of the split: the parts must sum back to the total EXACTLY, at
    /// every instalment count. A farmer paying in four must not be two cents
    /// short of what the operator is owed.
    func testThePartsAlwaysSumBackToTheTotal() throws {
        for cents in [1, 2, 3, 7, 99, 100, 101, 333_333, 375_006, 1_000_000, 99_999_999] {
            for instalments in 1...4 {
                let q = try XCTUnwrap(
                    InsurancePremium.quote(sumInsuredCents: cents * 10,
                                           instalments: instalments),
                    "no quote for \(cents) over \(instalments)")
                XCTAssertEqual(q.instalmentsCents.reduce(0, +), q.premiumCents,
                               "\(cents)c over \(instalments) does not sum back")
                XCTAssertEqual(q.instalmentsCents.count, instalments)
                // The leftover goes FIRST, so no later part exceeds the first.
                XCTAssertTrue(q.instalmentsCents.dropFirst().allSatisfy {
                    $0 <= q.instalmentsCents[0]
                }, "a later instalment exceeded the first at \(cents)c/\(instalments)")
            }
        }
    }

    /// Round-half-up, at the boundary in both directions. A sum insured of
    /// 5 cents at 1000 bp is exactly half a cent of premium.
    func testTheHalfCentRoundsUpRatherThanTruncating() throws {
        // 5c × 1000bp = 5000; +5000 = 10000; /10000 = 1 exactly.
        XCTAssertEqual(try XCTUnwrap(
            InsurancePremium.quote(sumInsuredCents: 5, instalments: 1)).premiumCents, 1)
        // 4c × 1000bp = 4000; +5000 = 9000; /10000 = 0 → refused, not zero.
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 4, instalments: 1))
    }

    func testAnImpossibleInputHasNoQuoteRatherThanAZeroOne() {
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 0, instalments: 1))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: -1, instalments: 1))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 10_000, instalments: 0))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 10_000, instalments: 5))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 10_000,
                                            tariffBp: 0, instalments: 1))
    }
}

/// The parser asymmetry, which is the server's and is deliberate.
///
/// For MONEY a single separator followed by exactly three digits means
/// thousands. For AREA both «,» and «.» are always decimal. Same two
/// characters, opposite meanings, because «100 000» lev and «12,345» decares
/// are both what a farmer actually types.
final class InsuranceParserTests: XCTestCase {

    func testMoneyReadsThreeDigitsAfterASeparatorAsThousands() {
        XCTAssertEqual(InsurancePremium.moneyCents("100 000"), 10_000_000)
        XCTAssertEqual(InsurancePremium.moneyCents("100.000"), 10_000_000)
        XCTAssertEqual(InsurancePremium.moneyCents("100,000"), 10_000_000)
        XCTAssertEqual(InsurancePremium.moneyCents("1 234 567"), 123_456_700)
    }

    func testMoneyReadsOneOrTwoDigitsAsCents() {
        XCTAssertEqual(InsurancePremium.moneyCents("100,50"), 10_050)
        XCTAssertEqual(InsurancePremium.moneyCents("100.5"), 10_050)
        XCTAssertEqual(InsurancePremium.moneyCents("37 500,55"), 3_750_055)
        XCTAssertEqual(InsurancePremium.moneyCents("250"), 25_000)
    }

    /// THE DOCUMENTED COST of the money rule, asserted so it is a decision
    /// rather than a surprise: «0,123» reads as 123, not as 0.123. A sum
    /// insured below one currency unit is not something this form expresses,
    /// and the alternative — three digits sometimes decimal — makes «100 000»
    /// ambiguous, which is the case that actually occurs.
    func testTheCostOfTheThousandsRuleIsWrittenDown() {
        XCTAssertEqual(InsurancePremium.moneyCents("0,123"), 12_300)
    }

    /// Refused rather than truncated. Silently dropping a digit from a sum
    /// insured produces a real number that reaches an operator.
    func testMoreThanTwoFractionalDigitsIsRefused() {
        XCTAssertNil(InsurancePremium.moneyCents("100,1234"))
        XCTAssertNil(InsurancePremium.moneyCents("1 000,12345"))
    }

    func testAreaTreatsBothSeparatorsAsDecimal() throws {
        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("12,345")),
                       12.345, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("12.345")),
                       12.345, accuracy: 0.0000001)
        // A space is grouping in either reading, so it is not decimal.
        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("1 000,5")),
                       1000.5, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("250")),
                       250, accuracy: 0.0000001)
    }

    /// The asymmetry in one assertion, so nobody "fixes" one side to match
    /// the other: the SAME string is 12345 lev and 12.345 decares.
    func testTheSameStringMeansDifferentThingsForMoneyAndArea() throws {
        XCTAssertEqual(InsurancePremium.moneyCents("12,345"), 1_234_500)
        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("12,345")),
                       12.345, accuracy: 0.0000001)
    }

    func testNonsenseIsRefusedRatherThanReadAsZero() {
        for text in ["", "   ", "abc", "12a", "-5", "1,2,3,4"] {
            XCTAssertNil(InsurancePremium.moneyCents(text), "money accepted «\(text)»")
        }
        for text in ["", "abc", "12a", "-5"] {
            XCTAssertNil(InsurancePremium.areaDecares(text), "area accepted «\(text)»")
        }
    }
}

/// The product list, which is compiled in PROVISIONALLY and should not be.
final class InsuranceProductTests: XCTestCase {

    /// The server's `productKey` enum, verbatim, so a fetched catalogue drops
    /// straight in. Order is the server's too.
    func testTheKeysAreTheServersEnum() {
        XCTAssertEqual(InsuranceProduct.allCases.map(\.rawValue),
                       ["wheat", "barley", "maize", "sunflower", "rapeseed",
                        "drought", "hail", "frost"])
    }

    /// FIVE OF THE EIGHT ARE COMMODITIES, and this app already has a Bulgarian
    /// name for each. If a fetched catalogue ever returns a different label for
    /// `wheat` than `CommodityName` does, the app shows two Bulgarian names for
    /// one crop on two screens — worse than either alone. This asserts the
    /// equality is deliberate so nobody resolves it by hardcoding a second
    /// spelling.
    func testCropProductsAreNamedByCommodityNameRatherThanSpelledHere() {
        for product in InsuranceProduct.allCases where product.isCrop {
            XCTAssertEqual(product.label,
                           CommodityName.canonical(product.rawValue),
                           "\(product.rawValue) is not named by CommodityName")
        }
    }

    /// The three perils have no commodity to resolve, so they are named here
    /// and must not be blank or left as an English slug.
    func testPerilsAreNamedInBulgarian() {
        for product in InsuranceProduct.allCases where !product.isCrop {
            XCTAssertFalse(product.label.isEmpty)
            XCTAssertNotEqual(product.label, product.rawValue,
                              "\(product.rawValue) reached a farmer in English")
            XCTAssertTrue(product.label.unicodeScalars.contains {
                $0.value >= 0x0400 && $0.value <= 0x04FF
            }, "\(product.rawValue) is not Cyrillic: \(product.label)")
        }
    }
}
