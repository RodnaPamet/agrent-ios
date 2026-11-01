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

    /// One row per type, biggest first, each with its count and its sum;
    /// a sum never across currencies.
    func testOneRowPerTypeBiggestFirst() async throws {
        let breakdown = CostBreakdown(try await entries())
        XCTAssertEqual(breakdown.groups.map(\.category), [.fertilizer, .pesticide, .fuel])
        XCTAssertEqual(breakdown.groups[0].count, 3)
        XCTAssertEqual(breakdown.groups[0].totals.text, Money.text(8006.04, "EUR"))
        XCTAssertEqual(breakdown.groups[2].totals.map(\.currency), ["EUR", "BGN"], "EUR first, then the others, never added together")
        XCTAssertEqual(breakdown.count, 6)
        XCTAssertEqual(breakdown.available, [.fertilizer, .pesticide, .fuel])
        XCTAssertEqual(breakdown.otherCurrencies, ["BGN"])
    }

    /// The chips: several types at once; none is «Всички». The chips keep
    /// offering every type whatever is chosen.
    func testTheChipsFilterEverything() async throws {
        let some = CostBreakdown(try await entries(), chosen: [.pesticide, .fuel])
        XCTAssertEqual(Set(some.groups.map(\.category)), [.pesticide, .fuel])
        XCTAssertEqual(some.count, 3)
        XCTAssertEqual(some.available, [.fertilizer, .pesticide, .fuel])
        XCTAssertFalse(some.months.contains { $0.category == .fertilizer })
        let all = CostBreakdown(try await entries(), chosen: [])
        XCTAssertEqual(all.count, 6)
    }

    /// Months by `incurredOn`, in UTC, EUR only; a type's own months for its
    /// graph.
    func testMonthsAreEurByType() async throws {
        let breakdown = CostBreakdown(try await entries())
        let months = Set(breakdown.months.map { BgDate.isoDay($0.month) })
        XCTAssertEqual(months.count, 2, "September and October")
        let october = breakdown.months.filter { $0.month == CostBreakdown.month(of: BgDate.parseISODay("2026-10-15")!) }
        XCTAssertEqual(october.first { $0.category == .fertilizer }?.amount ?? 0, 6226.92, accuracy: 0.001)
        XCTAssertEqual(october.first { $0.category == .fuel }?.amount ?? 0, 200, accuracy: 0.001, "the BGN fuel is left out")
        XCTAssertEqual(breakdown.months(of: .fertilizer).count, 2)
        XCTAssertEqual(BgDate.monthShort(CostBreakdown.month(of: BgDate.parseInstant("2026-10-01T00:00:00.000Z")!)), "окт")
        // The 1st, stored as UTC midnight, is October on a phone west of
        // Greenwich too, and the bar sits at that phone's own midnight.
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(identifier: "America/New_York")!
        let first = CostBreakdown.month(of: BgDate.parseInstant("2026-10-01T00:00:00.000Z")!, in: west)
        XCTAssertEqual(west.component(.month, from: first), 10)
        XCTAssertEqual(west.component(.day, from: first), 1)
        XCTAssertEqual(west.component(.hour, from: first), 0)
        // ICU puts a no-break space before «г.».
        XCTAssertTrue(BgDate.monthYear(BgDate.parseInstant("2026-10-01T00:00:00.000Z")!).hasPrefix("октомври 2026"))
    }
}
