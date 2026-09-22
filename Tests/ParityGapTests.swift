import XCTest
@testable import Agrent

/// PARITY GAP 1. The app decoded only `netWorthUnavailableReason` and
/// rendered it, so a Bulgarian screen showed an English sentence every time
/// net worth could not be computed — an ORDINARY state on this payload.
final class RefusalTextTests: XCTestCase {

    func testAKnownCodeIsTranslated() {
        XCTAssertEqual(
            RefusalText.resolve(
                code: "MIXED_COST_CURRENCY", params: nil,
                fallback: "Costs are recorded in more than one currency."),
            UserMessage.bulgarian["MIXED_COST_CURRENCY"]
        )
    }

    /// `explainRefusal`'s own rule: an unrecognised code falls back to the
    /// server's English rather than to nothing. A future code must still
    /// say something.
    func testAnUnknownCodeFallsBackToTheServersEnglish() {
        XCTAssertEqual(
            RefusalText.resolve(
                code: "SOME_FUTURE_REFUSAL", params: nil,
                fallback: "Something the server can explain and we cannot."),
            "Something the server can explain and we cannot."
        )
    }

    func testNoCodeAtAllStillUsesTheFallback() {
        XCTAssertEqual(RefusalText.resolve(code: nil, params: nil, fallback: "x"), "x")
        XCTAssertNil(RefusalText.resolve(code: nil, params: nil, fallback: nil))
    }

    /// THE divergence from the web, and the reason this type exists.
    ///
    /// `{commodity}` is a canonical SLUG. The web passes params straight to
    /// its translator with no lookup, so it renders "Няма налична пазарна
    /// цена за wheat" — a Bulgarian sentence with an English slug in it,
    /// the same defect the owner reported, one layer further in.
    func testTheCommodityParamIsTranslatedNotPastedIn() {
        let text = RefusalText.resolve(
            code: "NO_MARKET_PRICE",
            params: ["commodity": "wheat"],
            fallback: "No market price for wheat."
        )
        XCTAssertEqual(text, "Няма налична пазарна цена за Пшеница.")
        XCTAssertFalse(text!.contains("wheat"), text!)
        XCTAssertFalse(text!.contains("{"), text!)
    }

    /// A slug in no catalogue still must not appear raw inside a Bulgarian
    /// sentence — it title-cases, the same rule as everywhere else.
    func testAnUnknownCommoditySlugIsTitleCased() {
        let text = RefusalText.resolve(
            code: "NO_MARKET_PRICE",
            params: ["commodity": "sugar-beet"], fallback: nil)
        XCTAssertEqual(text, "Няма налична пазарна цена за Sugar Beet.")
    }

    /// Currency codes are substituted as-is: BGN and EUR are ISO and read
    /// the same in both languages.
    func testCurrencyCodesAreSubstitutedVerbatim() {
        let text = RefusalText.resolve(
            code: "COST_PRICE_CURRENCY_MISMATCH",
            params: ["costCurrency": "BGN", "priceCurrency": "EUR"],
            fallback: nil
        )
        XCTAssertTrue(text!.contains("BGN"), text!)
        XCTAssertTrue(text!.contains("EUR"), text!)
        XCTAssertFalse(text!.contains("{"), text!)
    }

    /// A placeholder the resolver does not know is LEFT AS WRITTEN, not
    /// blanked. A visible `{foo}` is reportable; a sentence silently
    /// missing a clause is not — and on a refusal screen the missing
    /// clause is the reason.
    func testAnUnrecognisedPlaceholderSurvivesVisibly() {
        let text = RefusalText.resolve(
            code: "NO_MARKET_PRICE", params: [:], fallback: nil)
        XCTAssertEqual(text, "Няма налична пазарна цена за {commodity}.")
    }

    /// Every one of the four is Bulgarian and none carries a stray
    /// placeholder this app cannot fill.
    func testTheFourRefusalStringsAreWellFormed() {
        let known = ["NO_MARKET_PRICE", "MIXED_COST_CURRENCY",
                     "RENT_CURRENCY_UNRECORDED", "COST_PRICE_CURRENCY_MISMATCH"]
        let fillable: Set<String> = ["{commodity}", "{costCurrency}", "{priceCurrency}"]
        for code in known {
            let s = UserMessage.bulgarian[code]
            XCTAssertNotNil(s, code)
            XCTAssertTrue(s!.unicodeScalars.contains { $0.value > 0x400 }, code)
            // Extracted by scanning for braces, NOT by splitting on
            // spaces — that keeps the trailing punctuation, so
            // "{commodity}." never matches "{commodity}" and the test
            // fails on correct strings. Its own first run did exactly
            // that.
            for placeholder in Self.placeholders(in: s!) {
                XCTAssertTrue(
                    fillable.contains(placeholder),
                    "\(code) needs a param this app does not substitute: \(placeholder)"
                )
            }
        }
    }
}

extension RefusalTextTests {
    /// Every `{…}` in a string, punctuation excluded.
    static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for ch in text {
            if ch == "{" { current = "{" }
            else if ch == "}", var open = current { open.append("}"); found.append(open); current = nil }
            else if current != nil { current!.append(ch) }
        }
        return found
    }
}

/// PARITY GAP 6. The journal was `?limit=50` with no cursor, so a tenant
/// past fifty entries saw a truncated history and NOTHING SAID SO.
final class JournalPagingTests: XCTestCase {

    func testTheFirstPageAsksForALimitAndNoCursor() {
        let path = JournalAPI.path(cursor: nil)
        XCTAssertTrue(path.contains("limit=50"), path)
        XCTAssertFalse(path.contains("cursor="), path)
    }

    /// A cursor is opaque server output and `APIClient.url(for:)` takes the
    /// query VERBATIM, so anything not alphanumeric has to be encoded here
    /// or it changes the request.
    func testACursorIsPercentEncoded() {
        let path = JournalAPI.path(cursor: "a+b/c=d")
        XCTAssertFalse(path.contains("+"), path)
        XCTAssertFalse(path.contains("/c="), path)
        XCTAssertTrue(path.contains("cursor=a%2Bb%2Fc%3Dd"), path)
    }

    func testAnEmptyCursorIsTreatedAsNone() {
        XCTAssertEqual(JournalAPI.path(cursor: ""), JournalAPI.path(cursor: nil))
    }

    /// The bare-array branch has no cursor, and that is correct rather than
    /// a gap: an unpaginated response IS everything there is.
    func testABareArrayReportsNoMore() async throws {
        let json = #"""
        [{"id":"e1","type":"ACTIVITY","status":"DONE","title":"t",
          "occurredAt":"2026-09-11T00:00:00.000Z"}]
        """#
        let slice = try await JournalAPI.decodeList(from: Data(json.utf8))
        XCTAssertEqual(slice.entries.count, 1)
        XCTAssertFalse(slice.hasMore)
    }

    func testAnEnvelopeCarriesItsCursorThrough() async throws {
        let json = #"""
        {"rows":[{"id":"e1","type":"ACTIVITY","status":"DONE","title":"t",
          "occurredAt":"2026-09-11T00:00:00.000Z"}],"nextCursor":"abc"}
        """#
        let slice = try await JournalAPI.decodeList(from: Data(json.utf8))
        XCTAssertEqual(slice.nextCursor, "abc")
        XCTAssertTrue(slice.hasMore)
    }
}

/// PARITY GAP 2. The board sent no query string at all — no search, no
/// filter, and no way to reach page two.
final class ExchangeQueryTests: XCTestCase {

    func testAnUnfilteredQuerySendsOnlyALimit() {
        let path = ExchangeAPI.listingsPath(ExchangeQuery())
        XCTAssertTrue(path.hasSuffix("listings?limit=50"), path)
    }

    func testSearchAndTonnageReachTheQueryString() {
        var q = ExchangeQuery()
        q.text = "пшеница"
        q.minTonnes = 50
        q.maxTonnes = 500
        let path = ExchangeAPI.listingsPath(q)
        XCTAssertTrue(path.contains("minTonnes=50"), path)
        XCTAssertTrue(path.contains("maxTonnes=500"), path)
        XCTAssertTrue(path.contains("q=%D0%BF"), path)
    }

    /// A search term is arbitrary operator input and the query is taken
    /// verbatim by the URL builder, so an unencoded `&` would forge a
    /// parameter.
    func testASearchTermCannotForgeAParameter() {
        var q = ExchangeQuery()
        q.text = "wheat&limit=9999"
        let path = ExchangeAPI.listingsPath(q)
        XCTAssertEqual(path.components(separatedBy: "limit=").count - 1, 1, path)
    }

    func testBlankSearchIsOmittedRatherThanSentEmpty() {
        var q = ExchangeQuery()
        q.text = "   "
        XCTAssertFalse(ExchangeAPI.listingsPath(q).contains("q="))
    }

    /// A filter change must NOT carry the old cursor: it is positional
    /// against the previous result set, so reusing it appends page two of
    /// a different search.
    func testChangingAFilterResetsPaging() {
        var q = ExchangeQuery()
        q.cursor = "page2"
        q.text = "wheat"
        XCTAssertNil(q.firstPage.cursor)
        XCTAssertEqual(q.firstPage.text, "wheat")
    }

    func testIsFilteredReflectsEveryFilter() {
        XCTAssertFalse(ExchangeQuery().isFiltered)
        var q = ExchangeQuery(); q.text = "x"
        XCTAssertTrue(q.isFiltered)
        var t = ExchangeQuery(); t.minTonnes = 50
        XCTAssertTrue(t.isFiltered)
        var blank = ExchangeQuery(); blank.text = "  "
        XCTAssertFalse(blank.isFiltered, "whitespace is not a filter")
    }

    /// The bands are a UI over `minTonnes`/`maxTonnes`, so a round trip
    /// through a query must land on the same band.
    func testEveryBandRoundTrips() {
        for band in TonnageBand.allCases {
            var q = ExchangeQuery()
            q.minTonnes = band.min
            q.maxTonnes = band.max
            XCTAssertEqual(TonnageBand.matching(q), band, band.rawValue)
        }
    }

    /// A combination no band produces — an older build, or a hand-built
    /// query — falls back to `.any` rather than being silently rewritten.
    func testAnUnrecognisedRangeDoesNotMasqueradeAsABand() {
        var q = ExchangeQuery()
        q.minTonnes = 17
        q.maxTonnes = 23
        XCTAssertEqual(TonnageBand.matching(q), .any)
    }
}

/// The exchange's decimals are STRINGS on the wire — its routes have no
/// DTO, unlike `grain/costs` which maps through one and sends numbers.
final class ExchangeDecimalTests: XCTestCase {

    /// The reciprocal of the money-formatting bug: the wire uses `.`
    /// regardless of the device, and a locale that groups with `.` reads
    /// "12.5" as 125 — a factor of ten on a tonnage being priced.
    func testWireStringsParseWithTheWireSeparator() {
        XCTAssertEqual(WireDecimal.parse("12.5"), Decimal(string: "12.5"))
        XCTAssertEqual(WireDecimal.parse("1234.50"), Decimal(string: "1234.5"))
        XCTAssertNotEqual(WireDecimal.parse("12.5"), Decimal(125))
    }

    func testNilAndNonsenseParseToNil() {
        XCTAssertNil(WireDecimal.parse(nil))
        XCTAssertNil(WireDecimal.parse("abc"))
    }
}
