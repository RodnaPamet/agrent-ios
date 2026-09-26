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

/// What the quote puts ON THE WIRE, and what it deliberately leaves off.
final class InsuranceQuoteWireTests: XCTestCase {

    private func encoded(_ lead: CreateLead) throws -> [String: Any] {
        let data = try JSONEncoder().encode(lead)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func lead(quote: CreateLead.Quote?) -> CreateLead {
        CreateLead(parcelId: "p1", message: "Запитване.", locationId: "l1",
                   risk: nil, quote: quote)
    }

    /// A MESSAGE-ONLY ASK OMITS `quote` ENTIRELY rather than sending null.
    ///
    /// The server requires a non-blank message OR a quote. An explicit
    /// `"quote": null` would be a quote key present with nothing in it, and
    /// this app already shipped one bug from sending a shape the schema
    /// refused — every enquiry 400'd for weeks on `message invalid_type`.
    func testAMessageOnlyAskSendsNoQuoteKey() throws {
        let json = try encoded(lead(quote: nil))
        XCTAssertNil(json["quote"], "a nil quote was encoded as a key")
        XCTAssertFalse((json["message"] as? String ?? "").isEmpty)
    }

    /// FOUR INPUTS AND NO PRICE. The server strips a price if one is sent and
    /// recomputes; a client that sent its own figure would be asserting
    /// authority it does not have.
    func testTheQuoteCarriesTheFourInputsAndNoPrice() throws {
        let json = try encoded(lead(quote: CreateLead.Quote(
            productKey: "wheat", areaDca: 250, sumInsuredCents: 3_750_055,
            instalments: 4, areaScope: nil)))
        let quote = try XCTUnwrap(json["quote"] as? [String: Any])

        XCTAssertEqual(quote["productKey"] as? String, "wheat")
        XCTAssertEqual(quote["areaDca"] as? Double, 250)
        XCTAssertEqual(quote["sumInsuredCents"] as? Int, 3_750_055)
        XCTAssertEqual(quote["instalments"] as? Int, 4)

        for absent in ["premiumCents", "premium", "price", "tariffBp",
                       "instalmentsCents", "perDecareCents"] {
            XCTAssertNil(quote[absent], "the request carried «\(absent)»")
        }
    }

    /// `areaScope` is omitted when it IS the parcel, because that is the
    /// server's default. Sending "parcel" explicitly would work and would also
    /// be a second statement of the same fact.
    func testAreaScopeIsOnlySentWhenItIsNotTheParcel() throws {
        let asParcel = try encoded(lead(quote: CreateLead.Quote(
            productKey: "hail", areaDca: 10, sumInsuredCents: 100_000,
            instalments: 1, areaScope: nil)))
        XCTAssertNil(try XCTUnwrap(asParcel["quote"] as? [String: Any])["areaScope"])

        let asCustom = try encoded(lead(quote: CreateLead.Quote(
            productKey: "hail", areaDca: 10, sumInsuredCents: 100_000,
            instalments: 1, areaScope: CreateLead.Quote.scopeCustom)))
        XCTAssertEqual(
            try XCTUnwrap(asCustom["quote"] as? [String: Any])["areaScope"] as? String,
            "custom")
    }

    /// `crop-at-location` needs `coveredParcelCount` and is a 400 without it.
    /// This app produces only the two scopes it can satisfy, and this asserts
    /// the third is not reachable by a typo in a string literal.
    func testTheOnlyScopesThisAppCanProduceAreTheOnesItCanSatisfy() {
        XCTAssertEqual(CreateLead.Quote.scopeParcel, "parcel")
        XCTAssertEqual(CreateLead.Quote.scopeCustom, "custom")
    }
}

/// The idempotency key, whose whole value is in when it is REUSED.
@MainActor
final class InsuranceIdempotencyTests: XCTestCase {

    private func quote(sumInsuredCents: Int = 100_000,
                       instalments: Int = 1) -> CreateLead.Quote {
        CreateLead.Quote(productKey: "wheat", areaDca: 100,
                         sumInsuredCents: sumInsuredCents,
                         instalments: instalments, areaScope: nil)
    }

    /// A RETRY IS THE SAME ASK: unchanged inputs must produce the same
    /// fingerprint, so the store reuses the key and the server replays the
    /// original lead instead of writing a second row and emailing again.
    func testUnchangedInputsAreTheSameAsk() {
        let a = FarmRiskStore.fingerprint(parcelID: "p1", quote: quote())
        let b = FarmRiskStore.fingerprint(parcelID: "p1", quote: quote())
        XCTAssertEqual(a, b)
    }

    /// EVERY INPUT CHANGES IT, including the parcel. Leaving the parcel out
    /// would have replayed the first parcel's lead when a farmer moved on to
    /// the next field.
    func testAnyChangedInputIsADifferentAsk() {
        let base = FarmRiskStore.fingerprint(parcelID: "p1", quote: quote())
        XCTAssertNotEqual(base, FarmRiskStore.fingerprint(parcelID: "p2", quote: quote()))
        XCTAssertNotEqual(base, FarmRiskStore.fingerprint(
            parcelID: "p1", quote: quote(sumInsuredCents: 100_001)))
        XCTAssertNotEqual(base, FarmRiskStore.fingerprint(
            parcelID: "p1", quote: quote(instalments: 2)))
        XCTAssertNotEqual(base, FarmRiskStore.fingerprint(
            parcelID: "p1",
            quote: CreateLead.Quote(productKey: "barley", areaDca: 100,
                                    sumInsuredCents: 100_000, instalments: 1,
                                    areaScope: nil)))
        XCTAssertNotEqual(base, FarmRiskStore.fingerprint(
            parcelID: "p1",
            quote: CreateLead.Quote(productKey: "wheat", areaDca: 100.5,
                                    sumInsuredCents: 100_000, instalments: 1,
                                    areaScope: nil)))
    }

    /// A message-only ask is distinguishable from a quoted one, so toggling the
    /// calculator off after a failure is a new ask rather than a replay.
    func testAMessageOnlyAskIsNotTheSameAsAQuotedOne() {
        XCTAssertNotEqual(FarmRiskStore.fingerprint(parcelID: "p1", quote: nil),
                          FarmRiskStore.fingerprint(parcelID: "p1", quote: quote()))
    }
}

/// When the server disagrees with the estimate.
@MainActor
final class InsuranceCorrectionNoticeTests: XCTestCase {

    private let sent = CreateLead.Quote(
        productKey: "wheat", areaDca: 250, sumInsuredCents: 3_750_055,
        instalments: 4, areaScope: nil)

    /// SILENCE WHEN THEY AGREE. The estimate was right, it was shown, and
    /// saying so again is noise on top of a confirmation.
    func testAgreementSaysNothing() {
        let got = CreatedLead.ServerQuote(
            premiumCents: 375_006, instalmentsCents: [93_753, 93_751, 93_751, 93_751],
            tariffBp: 1000, engineVersion: "1")
        XCTAssertNil(FarmRiskStore.correctionNotice(sent: sent, got: got))
    }

    /// A DIFFERENT TARIFF SERVER-SIDE is the case this exists for: the phone
    /// carries 1000 bp, the server has moved on, and the figure the farmer read
    /// is not the one the operator received.
    func testADisagreementNamesBothNumbers() throws {
        let got = CreatedLead.ServerQuote(
            premiumCents: 450_007, instalmentsCents: [112_504, 112_501, 112_501, 112_501],
            tariffBp: 1200, engineVersion: "1")
        let notice = try XCTUnwrap(
            FarmRiskStore.correctionNotice(sent: sent, got: got))
        XCTAssertTrue(notice.contains(InsurancePremium.eur(450_007)), notice)
        XCTAssertTrue(notice.contains(InsurancePremium.eur(375_006)), notice)
    }

    /// No quote sent, or none returned, is nothing to explain rather than a
    /// notice comparing against zero.
    func testNothingToCompareIsNoNotice() {
        XCTAssertNil(FarmRiskStore.correctionNotice(sent: nil, got: nil))
        XCTAssertNil(FarmRiskStore.correctionNotice(sent: sent, got: nil))
        XCTAssertNil(FarmRiskStore.correctionNotice(
            sent: nil,
            got: CreatedLead.ServerQuote(premiumCents: 1, instalmentsCents: [1],
                                         tariffBp: 1000, engineVersion: nil)))
    }
}

/// A SPACE IS NEVER A DECIMAL SEPARATOR.
///
/// Found by the server session, which checked its own parsers after I sent it
/// the «1,2,3,4» case and found the same hole behind SPACES — in both its
/// money and its area parser. Mine already refused «1 2 3 4», because the
/// grouping check looks at the groups BETWEEN the first and the last and there
/// were two of them. It never looked at a two-group input, so «1 23» read as
/// 1.23 and «1 2» as 1.2.
///
/// The shape of the bug I had in mind was the shape I had already fixed. These
/// are the inputs, not the rule.
final class InsuranceSpaceSeparatorTests: XCTestCase {

    func testASpaceCannotOpenADecimalTail() {
        for text in ["1 23", "1 2", "12 34", "1 2 3 4", "12 3456", "100 00"] {
            XCTAssertNil(InsurancePremium.moneyCents(text), "money accepted «\(text)»")
            XCTAssertNil(InsurancePremium.areaDecares(text), "area accepted «\(text)»")
        }
    }

    /// The other direction, which is the one this kind of fix breaks: every
    /// shape a farmer actually types still parses.
    func testEverythingValidStillParses() throws {
        XCTAssertEqual(InsurancePremium.moneyCents("100 000"), 10_000_000)
        XCTAssertEqual(InsurancePremium.moneyCents("12 345"), 1_234_500)
        XCTAssertEqual(InsurancePremium.moneyCents("100 000,50"), 10_000_050)
        XCTAssertEqual(InsurancePremium.moneyCents("1 234 567.89"), 123_456_789)
        XCTAssertEqual(InsurancePremium.moneyCents("  37 500,55  "), 3_750_055)
        XCTAssertEqual(InsurancePremium.moneyCents("100,50"), 10_050)

        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("1 000,5")),
                       1000.5, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(InsurancePremium.areaDecares("12,345")),
                       12.345, accuracy: 0.0000001)
    }

    /// A letter anywhere is refused rather than skipped. The old splitter
    /// dropped unknown characters by filtering empty components, so «12a34»
    /// could have become two groups; this walks the string and refuses.
    func testANonDigitIsRefusedRatherThanSkipped() {
        for text in ["12a34", "1,2a", "а100", "100 000x"] {
            XCTAssertNil(InsurancePremium.moneyCents(text), "money accepted «\(text)»")
            XCTAssertNil(InsurancePremium.areaDecares(text), "area accepted «\(text)»")
        }
    }
}
