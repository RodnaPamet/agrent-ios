import Foundation

/// «Разходи» by type (#500, owner 2026-11-01): what the folded rows, the
/// type chips and the three graphs are drawn from.
///
/// One value, computed from the list the screen already reads
/// (`GET /grain/costs`, the newest 500), so the rows, the totals and the
/// graphs cannot disagree about which expenses they mean.
///
/// ── Money, per currency ──
///
/// Totals are summed in `Decimal`, per currency, and never across one: the
/// app is EUR-only now (#456), but an older row may still carry another
/// code, and adding BGN to EUR would print a number no ledger has. The
/// graphs draw EUR only, and `otherCurrencies` says what they left out.
struct CostBreakdown: Equatable {
    /// The currency the graphs are drawn in.
    static let chartCurrency = "EUR"

    struct TypeGroup: Identifiable, Equatable {
        let category: CostCategory
        /// Newest first, as the list reads.
        let entries: [CostEntry]
        /// Sum per currency, EUR first.
        let totals: [Total]
        var id: CostCategory { category }
        var count: Int { entries.count }
        /// What the graphs and the order use.
        var chartAmount: Double { totals.first { $0.currency == CostBreakdown.chartCurrency }?.double ?? 0 }
    }

    struct Total: Equatable {
        let currency: String
        let amount: Decimal
        var double: Double { NSDecimalNumber(decimal: amount).doubleValue }
    }

    /// One bar segment: a type's EUR spending in one month.
    struct MonthAmount: Equatable, Identifiable {
        /// The first day of the month, at midnight UTC.
        let month: Date
        let category: CostCategory
        let amount: Double
        var id: String { "\(month.timeIntervalSince1970)-\(category.rawValue)" }
    }

    /// Every type in the list, biggest first: what the chips offer.
    let available: [CostCategory]
    /// The chosen types' groups, biggest first (EUR), then by name.
    let groups: [TypeGroup]
    /// All chosen expenses, summed per currency.
    let totals: [Total]
    let count: Int
    /// EUR per month and type, oldest month first.
    let months: [MonthAmount]
    /// Currencies present among the chosen expenses that the graphs leave out.
    let otherCurrencies: [String]

    /// `chosen` empty is «Всички».
    init(_ entries: [CostEntry], chosen: Set<CostCategory> = []) {
        let byType = Dictionary(grouping: entries, by: \.category)
        available = Self.biggestFirst(byType.map { Self.group($0.key, $0.value) }).map(\.category)

        let shown = chosen.isEmpty ? entries : entries.filter { chosen.contains($0.category) }
        groups = Self.biggestFirst(Dictionary(grouping: shown, by: \.category).map { Self.group($0.key, $0.value) })
        totals = Self.totals(shown)
        count = shown.count
        otherCurrencies = Array(Set(shown.map(\.currency)).subtracting([Self.chartCurrency])).sorted()

        var sums: [Date: [CostCategory: Decimal]] = [:]
        for entry in shown where entry.currency == Self.chartCurrency {
            sums[Self.month(of: entry.incurredOn), default: [:]][entry.category, default: 0] += entry.amount.value
        }
        months = sums.keys.sorted().flatMap { month in
            sums[month, default: [:]]
                .sorted { $0.key.label < $1.key.label }
                .map { MonthAmount(month: month, category: $0.key,
                                   amount: NSDecimalNumber(decimal: $0.value).doubleValue) }
        }
    }

    /// One type's months, for its own graph when it is opened.
    func months(of category: CostCategory) -> [MonthAmount] {
        months.filter { $0.category == category }
    }

    /// The month an expense falls in, as the 1st of that month at the
    /// PHONE's midnight.
    ///
    /// Which month: read in UTC, because `incurredOn` is a day the server
    /// stores as its UTC midnight, and read in a zone west of Greenwich the
    /// 1st would fall in the month before. Where on the axis: the phone's
    /// calendar, because that is the one Swift Charts buckets `unit: .month`
    /// and places its axis marks in. Built in UTC, the bars were right and
    /// every label one month early («авг» under September), measured on
    /// the simulator 2026-11-01.
    static func month(of date: Date, in calendar: Calendar = .current) -> Date {
        let parts = utc.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)) ?? date
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func group(_ category: CostCategory, _ entries: [CostEntry]) -> TypeGroup {
        TypeGroup(category: category, entries: entries.sorted { $0.incurredOn > $1.incurredOn },
                  totals: totals(entries))
    }

    private static func totals(_ entries: [CostEntry]) -> [Total] {
        var sums: [String: Decimal] = [:]
        for entry in entries { sums[entry.currency, default: 0] += entry.amount.value }
        return sums.map { Total(currency: $0.key, amount: $0.value) }
            .sorted { ($0.currency == chartCurrency ? 0 : 1, $0.currency) < ($1.currency == chartCurrency ? 0 : 1, $1.currency) }
    }

    private static func biggestFirst(_ groups: [TypeGroup]) -> [TypeGroup] {
        groups.sorted { ($0.chartAmount, $1.category.label) > ($1.chartAmount, $0.category.label) }
    }
}

extension CostBreakdown.Total {
    /// «11 119,50 EUR», at the money scale (`Money.text`).
    var text: String { Money.text(double, currency) }
}

extension Array where Element == CostBreakdown.Total {
    /// «11 119,50 EUR» or «11 119,50 EUR и 200,00 BGN»: never one sum
    /// across currencies.
    var text: String {
        isEmpty ? Money.text(0, CostBreakdown.chartCurrency) : map(\.text).joined(separator: " и ")
    }
}
