import XCTest
@testable import Agrent

/// «Разходи» by type (#500): the folded rows, the chips and the graphs all
/// read one `CostBreakdown`, so these pin what it counts.
final class CostBreakdownTests: XCTestCase {

    private func row(_ id: String, _ category: String, _ amount: String, _ day: String,
                     currency: String = "EUR") -> String {
        #"{"id":"\#(id)","category":"\#(category)","amount":"\#(amount)","currency":"\#(currency)","incurredOn":"\#(day)T00:00:00.000Z","createdAt":"2026-10-20T08:00:00.000Z","updatedAt":"2026-10-20T08:00:00.000Z"}"#
    }

    /// Through the app's own decoder, as the screen reads them.
    private func entries() async throws -> [CostEntry] {
        let rows = [
            row("a", "FERTILIZER", "3113.46", "2026-10-20"),
            row("b", "FERTILIZER", "3113.46", "2026-10-20"),
            row("c", "FERTILIZER", "1779.12", "2026-09-30"),
            row("d", "PESTICIDE", "1779.12", "2026-10-20"),
            row("e", "FUEL", "200", "2026-10-01"),
            row("f", "FUEL", "50", "2026-10-02", currency: "BGN"),
        ]
        let page = #"{"rows":[\#(rows.joined(separator: ","))],"totalCount":6,"truncated":false}"#
        let decoded = try await CostsAPI.decodeList(from: Data(page.utf8))
        XCTAssertEqual(decoded.items.count, 6, "positive control: every row decoded")
        return decoded.items
    }

    /// The server's totals for `entries()`, as #2656 sends them: integer
    /// cents per (type, stored currency) and per (type, month, currency).
    /// The «EURO» rent row is the phone's old free-text currency.
    private func summary(_ json: String? = nil) async throws -> CostSummary {
        let body = json ?? """
        {"byType":[
          {"category":"FERTILIZER","currency":"EUR","totalMinor":800604,"count":3},
          {"category":"PESTICIDE","currency":"EUR","totalMinor":177912,"count":1},
          {"category":"FUEL","currency":"EUR","totalMinor":20000,"count":1},
          {"category":"FUEL","currency":"BGN","totalMinor":5000,"count":1}],
         "byMonth":[],
         "byTypeAndMonth":[
          {"category":"FERTILIZER","month":"2026-10","currency":"EUR","totalMinor":622692,"count":2},
          {"category":"FERTILIZER","month":"2026-09","currency":"EUR","totalMinor":177912,"count":1},
          {"category":"PESTICIDE","month":"2026-10","currency":"EUR","totalMinor":177912,"count":1},
          {"category":"FUEL","month":"2026-10","currency":"EUR","totalMinor":20000,"count":1},
          {"category":"FUEL","month":"2026-10","currency":"BGN","totalMinor":5000,"count":1}],
         "currencies":[{"currency":"EUR","count":5},{"currency":"BGN","count":1}]}
        """
        return try await CostsAPI.decodeSummary(from: Data(body.utf8))
    }

    /// One row per type, biggest first, each with its count and its sum;
    /// a sum never across currencies.
    func testOneRowPerTypeBiggestFirst() async throws {
        let breakdown = CostBreakdown(summary: try await summary(), entries: try await entries())
        XCTAssertEqual(breakdown.groups.map(\.category), [.fertilizer, .pesticide, .fuel])
        XCTAssertEqual(breakdown.groups[0].count, 3)
        XCTAssertEqual(breakdown.groups[0].entries.last?.id, "c", "newest first")
        XCTAssertEqual(breakdown.groups[0].totals.text, Money.text(8006.04, "EUR"))
        XCTAssertEqual(breakdown.groups[2].totals.map(\.currency), ["EUR", "BGN"], "EUR first, then the others, never added together")
        XCTAssertEqual(breakdown.count, 6)
        XCTAssertEqual(breakdown.totals.map(\.minor), [998516, 5000])
        XCTAssertEqual(breakdown.totals.first?.amount, Decimal(string: "9985.16"))
        XCTAssertEqual(breakdown.available, [.fertilizer, .pesticide, .fuel])
        XCTAssertEqual(breakdown.otherCurrencies, ["BGN"])
        XCTAssertNil(breakdown.groups[0].shownNote, "the list holds all three")
    }

    /// The totals are the SERVER's, over every expense: a list capped at
    /// the newest rows shows what it holds and says how many there are.
    func testTheTotalsCountWhatTheListDoesNotHold() async throws {
        let newest = Array(try await entries().prefix(1))
        let breakdown = CostBreakdown(summary: try await summary(), entries: newest)
        let fertilizer = try XCTUnwrap(breakdown.groups.first { $0.category == .fertilizer })
        XCTAssertEqual(fertilizer.entries.count, 1)
        XCTAssertEqual(fertilizer.count, 3)
        XCTAssertEqual(fertilizer.totals.text, Money.text(8006.04, "EUR"), "not the one row's 3113,46")
        XCTAssertEqual(fertilizer.shownNote, "Показани 1 от 3 разхода.")
        XCTAssertEqual(breakdown.groups.map(\.category), [.fertilizer, .pesticide, .fuel],
                       "a type with no row in the list is still a type")
    }

    /// «EURO», the phone's old free-text currency, is the euro: one sum, one
    /// code, as agri-saas `EURO_SPELLINGS` reads it. Lev is not, here or in
    /// the summary: this adds amounts, and lev is not euros unconverted.
    func testTheEurosSpellingsAreOneCurrency() async throws {
        let rent = try await summary("""
        {"byType":[
          {"category":"RENT","currency":"EUR","totalMinor":1334340,"count":1},
          {"category":"RENT","currency":"EURO","totalMinor":4000,"count":1},
          {"category":"RENT","currency":" euros ","totalMinor":500,"count":1},
          {"category":"RENT","currency":"€","totalMinor":100,"count":1},
          {"category":"RENT","currency":"BGN","totalMinor":1000,"count":1}],
         "byMonth":[],
         "byTypeAndMonth":[
          {"category":"RENT","month":"2026-10","currency":"EUR","totalMinor":1334340,"count":1},
          {"category":"RENT","month":"2026-10","currency":"EURO","totalMinor":4000,"count":1},
          {"category":"RENT","month":"2026-10","currency":" euros ","totalMinor":500,"count":1},
          {"category":"RENT","month":"2026-10","currency":"€","totalMinor":100,"count":1},
          {"category":"RENT","month":"2026-10","currency":"BGN","totalMinor":1000,"count":1}],
         "currencies":[]}
        """)
        let breakdown = CostBreakdown(summary: rent, entries: [])
        XCTAssertEqual(breakdown.groups[0].totals.map(\.currency), ["EUR", "BGN"])
        XCTAssertEqual(breakdown.groups[0].totals.first?.amount, Decimal(string: "13389.40"))
        XCTAssertEqual(breakdown.groups[0].count, 5)
        XCTAssertEqual(breakdown.otherCurrencies, ["BGN"])
        XCTAssertEqual(breakdown.months.map(\.minor), [1338940], "one EUR bar, the lev left out")
        XCTAssertEqual(CostCurrency.code("EURO"), "EUR")
        XCTAssertEqual(CostCurrency.code(nil), "EUR", "a blank on an EUR-only farm is a missing label")
        XCTAssertEqual(CostCurrency.code("bgn"), "BGN")
        XCTAssertEqual(CostCurrency.code("USD"), "USD")
    }

    /// The dropdown: several types at once; none is «Всички». It keeps
    /// offering every type whatever is chosen.
    func testTheChipsFilterEverything() async throws {
        let some = CostBreakdown(summary: try await summary(), entries: try await entries(), chosen: [.pesticide, .fuel])
        XCTAssertEqual(Set(some.groups.map(\.category)), [.pesticide, .fuel])
        XCTAssertEqual(some.count, 3)
        XCTAssertEqual(some.totals.map(\.minor), [197912, 5000])
        XCTAssertEqual(some.available, [.fertilizer, .pesticide, .fuel])
        XCTAssertFalse(some.months.contains { $0.category == .fertilizer })
        XCTAssertEqual(some.chartTotal(in: nil).minor, 197912)
        let all = CostBreakdown(summary: try await summary(), entries: try await entries(), chosen: [])
        XCTAssertEqual(all.count, 6)
    }

    /// A row swiped away and waiting out its «Отмени» is off the totals
    /// too, so «Общо» agrees with the rows on screen.
    func testASwipedRowIsOffTheTotals() async throws {
        let all = try await entries()
        let gone = all.filter { $0.id == "a" }
        let breakdown = CostBreakdown(summary: try await summary(), entries: all.filter { $0.id != "a" }, hidden: gone)
        let fertilizer = try XCTUnwrap(breakdown.groups.first { $0.category == .fertilizer })
        XCTAssertEqual(fertilizer.count, 2)
        XCTAssertEqual(fertilizer.totals.first?.minor, 800604 - 311346)
        XCTAssertNil(fertilizer.shownNote, "two rows, two counted")
        let october = try XCTUnwrap(CostBreakdown.month("2026-10"))
        XCTAssertEqual(breakdown.months.first { $0.month == october && $0.category == .fertilizer }?.minor,
                       622692 - 311346)
        XCTAssertEqual(breakdown.count, 5)
    }

    /// Months are the summary's `YYYY-MM`, EUR only, at the phone's own
    /// midnight: a string has no zone to read it in.
    func testMonthsAreEurByType() async throws {
        let breakdown = CostBreakdown(summary: try await summary(), entries: try await entries())
        XCTAssertEqual(Set(breakdown.months.map(\.month)).count, 2, "September and October")
        let october = try XCTUnwrap(CostBreakdown.month("2026-10"))
        XCTAssertEqual(breakdown.months.first { $0.month == october && $0.category == .fertilizer }?.amount ?? 0,
                       6226.92, accuracy: 0.001)
        XCTAssertEqual(breakdown.months.first { $0.month == october && $0.category == .fuel }?.minor, 20000,
                       "the BGN fuel is left out")
        XCTAssertEqual(breakdown.chartTotal(in: october).minor, 622692 + 177912 + 20000)
        XCTAssertEqual(breakdown.chartTotal(in: nil).minor, 622692 + 177912 + 177912 + 20000)
        XCTAssertEqual(BgDate.monthShort(october), "окт")
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(identifier: "America/New_York")!
        let first = try XCTUnwrap(CostBreakdown.month("2026-10", in: west))
        XCTAssertEqual(west.component(.month, from: first), 10)
        XCTAssertEqual(west.component(.day, from: first), 1)
        XCTAssertEqual(west.component(.hour, from: first), 0)
        XCTAssertNil(CostBreakdown.month("2026-13"))
        XCTAssertNil(CostBreakdown.month("октомври"))
        // An expense's own month, as the server's `to_char` in UTC writes it.
        XCTAssertEqual(CostBreakdown.monthKey(of: BgDate.parseInstant("2026-10-01T00:00:00.000Z")!), "2026-10")
        XCTAssertEqual(CostBreakdown.monthKey(of: BgDate.parseInstant("2026-09-30T00:00:00.000Z")!), "2026-09")
        XCTAssertEqual(CostBreakdown.minor(Decimal(string: "3113.46")!), 311346)
        // ICU puts a no-break space before «г.».
        XCTAssertTrue(BgDate.monthYear(october).hasPrefix("октомври 2026"))
    }

    /// A summary that does not read is no summary: the screen shows the
    /// plain rows, never a total missing a row.
    func testASummaryRowThatDoesNotReadFailsTheSummary() async {
        let bad = Data(#"{"byType":[{"category":"RENT","currency":"EUR","count":1}],"byMonth":[],"byTypeAndMonth":[],"currencies":[]}"#.utf8)
        do {
            _ = try await CostsAPI.decodeSummary(from: bad)
            XCTFail("a row without its total decoded")
        } catch {}
        XCTAssertTrue(CostsAPI.summaryPath.hasSuffix("/grain/costs/summary"))
    }
}
