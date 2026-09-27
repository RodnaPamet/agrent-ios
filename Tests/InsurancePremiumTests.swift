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

    /// THE TARIFF IS NAMED HERE, not defaulted.
    ///
    /// It used to be `provisionalTariffBp` compiled into the app, and these
    /// cases silently relied on that default. It comes from the server's
    /// catalogue now, so the reference figures need the rate they were
    /// computed at stated alongside them — a parity test that borrows a live
    /// value proves nothing the day that value changes.
    private let referenceTariffBp = 1000

    /// A — 1000 dca, «100 000», 3 instalments.
    /// EUR 10,000.00 · 10.00/dca · 3,333.34 + 3,333.33 + 3,333.33
    func testReferenceCaseA() throws {
        let sum = try XCTUnwrap(InsurancePremium.moneyCents("100 000"))
        XCTAssertEqual(sum, 10_000_000)

        let q = try XCTUnwrap(InsurancePremium.quote(sumInsuredCents: sum, tariffBp: referenceTariffBp, instalments: 3))
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

        let q = try XCTUnwrap(InsurancePremium.quote(sumInsuredCents: sum, tariffBp: referenceTariffBp, instalments: 2))
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

        let q = try XCTUnwrap(InsurancePremium.quote(sumInsuredCents: sum, tariffBp: referenceTariffBp, instalments: 4))
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
                                           tariffBp: referenceTariffBp, instalments: instalments),
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
            InsurancePremium.quote(sumInsuredCents: 5, tariffBp: referenceTariffBp, instalments: 1)).premiumCents, 1)
        // 4c × 1000bp = 4000; +5000 = 9000; /10000 = 0 → refused, not zero.
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 4, tariffBp: referenceTariffBp, instalments: 1))
    }

    func testAnImpossibleInputHasNoQuoteRatherThanAZeroOne() {
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 0, tariffBp: referenceTariffBp, instalments: 1))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: -1, tariffBp: referenceTariffBp, instalments: 1))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 10_000, tariffBp: referenceTariffBp, instalments: 0))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 10_000, tariffBp: referenceTariffBp, instalments: 5))
        XCTAssertNil(InsurancePremium.quote(sumInsuredCents: 10_000, tariffBp: 0, instalments: 1))
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

/// `InsuranceProductTests` WAS HERE — three tests of a compiled-in enum.
///
/// The enum is gone: the catalogue is the server's and a copy of it here went
/// stale silently. What those tests asserted has moved:
///
///   the keys matching the server's enum        now the server's own list
///   crop labels equalling `CommodityName`      `InsuranceCatalogueTests`
///   perils being Cyrillic                      likewise, against fetched copy
///
///     git show a917bf3:Tests/InsurancePremiumTests.swift

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

/// When the server disagrees with the figure that was ON SCREEN.
///
/// It takes the shown premium rather than recomputing one. Recomputing would
/// be a second description of the number the farmer read — and could use a
/// different tariff than the preview used, since the tariff now comes from a
/// fetched catalogue per product.
@MainActor
final class InsuranceCorrectionNoticeTests: XCTestCase {

    private func server(_ cents: Int) -> CreatedLead.ServerQuote {
        CreatedLead.ServerQuote(premiumCents: cents, instalmentsCents: [cents],
                                tariffBp: 1000, engineVersion: "1")
    }

    /// SILENCE WHEN THEY AGREE. The estimate was right, it was shown, and
    /// saying so again is noise on top of a confirmation.
    func testAgreementSaysNothing() {
        XCTAssertNil(FarmRiskStore.correctionNotice(
            shownPremiumCents: 375_006, got: server(375_006)))
    }

    /// A DIFFERENT TARIFF SERVER-SIDE is the case this exists for: the phone
    /// priced from a cached catalogue, the server has moved on, and the figure
    /// the farmer read is not the one the operator received.
    func testADisagreementNamesBothNumbers() throws {
        let notice = try XCTUnwrap(FarmRiskStore.correctionNotice(
            shownPremiumCents: 375_006, got: server(450_007)))
        XCTAssertTrue(notice.contains(InsurancePremium.eur(450_007)), notice)
        XCTAssertTrue(notice.contains(InsurancePremium.eur(375_006)), notice)
    }

    /// No preview shown, or no quote returned, is nothing to explain rather
    /// than a notice comparing against zero. The first is the ordinary case
    /// for a message-only ask and for a refused preview.
    func testNothingToCompareIsNoNotice() {
        XCTAssertNil(FarmRiskStore.correctionNotice(shownPremiumCents: nil, got: nil))
        XCTAssertNil(FarmRiskStore.correctionNotice(shownPremiumCents: 1, got: nil))
        XCTAssertNil(FarmRiskStore.correctionNotice(
            shownPremiumCents: nil, got: server(1)))
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

/// The fetched catalogue — decoding, and the two refusals it drives.
@MainActor
final class InsuranceCatalogueTests: XCTestCase {

    private func catalogue(engineVersion: Int = 1,
                           wheatName: String = "Пшеница") async throws -> InsuranceCatalogue {
        let json = """
        {"engineVersion":\(engineVersion),"currencySymbol":"€","products":[
          {"key":"wheat","kind":"crop","commodity":"wheat","tariffBp":1000,
           "name":"\(wheatName)","blurb":"Покритие за пшеница."},
          {"key":"hail","kind":"peril","tariffBp":1200,
           "name":"Градушка","blurb":"Покритие срещу градушка."}]}
        """
        return try await InsuranceCatalogueAPI.decode(Data(json.utf8))
    }

    func testTheShapeDecodesAndCommodityIsOptional() async throws {
        let c = try await catalogue()
        XCTAssertEqual(c.engineVersion, 1)
        XCTAssertEqual(c.currencySymbol, "€")
        XCTAssertEqual(c.products.count, 2)
        XCTAssertEqual(c.product(key: "wheat")?.tariffBp, 1000)
        XCTAssertTrue(c.product(key: "wheat")?.isCrop == true)
        // A peril has no crop behind it, and `commodity` is the one optional
        // field in the schema.
        XCTAssertNil(c.product(key: "hail")?.commodity)
        XCTAssertFalse(c.product(key: "hail")?.isCrop == true)
    }

    /// THE TARIFF IS PER PRODUCT, which is why the compiled-in constant had to
    /// go rather than become a default: hail is 1200 bp where wheat is 1000,
    /// so a single app-wide rate was already wrong for six of the eight.
    func testEachProductCarriesItsOwnTariff() async throws {
        let c = try await catalogue()
        let wheat = try XCTUnwrap(c.product(key: "wheat"))
        let hail = try XCTUnwrap(c.product(key: "hail"))
        XCTAssertNotEqual(wheat.tariffBp, hail.tariffBp)

        let onWheat = try XCTUnwrap(InsurancePremium.quote(
            sumInsuredCents: 1_000_000, tariffBp: wheat.tariffBp, instalments: 1))
        let onHail = try XCTUnwrap(InsurancePremium.quote(
            sumInsuredCents: 1_000_000, tariffBp: hail.tariffBp, instalments: 1))
        XCTAssertEqual(onWheat.premiumCents, 100_000)
        XCTAssertEqual(onHail.premiumCents, 120_000)
    }

    /// A NEWER ENGINE MEANS STOP PREVIEWING. The local arithmetic was written
    /// against engine 1; past that, what this app computes is no longer what
    /// gets stored and emailed, so the form refuses rather than showing a
    /// figure it cannot defend.
    func testANewerEngineStopsTheLocalArithmeticBeingTrusted() async throws {
        let current = try await catalogue(engineVersion: 1)
        let newer = try await catalogue(engineVersion: 2)
        XCTAssertTrue(current.matchesLocalArithmetic)
        XCTAssertFalse(newer.matchesLocalArithmetic)
    }

    /// The runtime detector for a catalogue that names a crop differently from
    /// the rest of the app — which is what arriving in English would look like.
    ///
    /// This asserts the COMPARISON works, not that the server agrees. Nothing
    /// in a unit test can assert the latter: the strings come off a server, and
    /// a fixture written here compared against a mapping written here would
    /// agree with itself.
    func testADisagreeingCropNameIsDetected() async throws {
        let agreeing = try await catalogue()
        XCTAssertTrue(agreeing.labelsDisagreeingWithCommodityName.isEmpty)

        let english = try await catalogue(wheatName: "Wheat")
        let rows = english.labelsDisagreeingWithCommodityName
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.key, "wheat")
        XCTAssertEqual(rows.first?.fetched, "Wheat")
        XCTAssertEqual(rows.first?.ours, "Пшеница")
    }
}
