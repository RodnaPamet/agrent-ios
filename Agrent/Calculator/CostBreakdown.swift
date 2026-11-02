import Foundation

/// «Разходи» by type (#500, owner 2026-11-01): what the folded rows, the
/// type dropdown and the two graphs are drawn from.
///
/// ── The server's totals, the list's rows ──
///
/// Every count and sum comes from `GET /grain/costs/summary` (#503), exact
/// over the whole register. The rows a type unfolds to are the list's
/// (`GET /grain/costs`, the newest 500), and a type with more than the
/// list holds says «Показани N от M». The phone never sums the list: two
/// ways to one total would be two totals on one screen.
///
/// A row swiped away and waiting out its five seconds of «Отмени» is taken
/// off the server's figures here, so the totals agree with the rows the
/// person can see.
///
/// ── Money, per currency ──
///
/// Totals are integer cents per currency and never across one: the app is
/// EUR-only now (#456), but an older row may still carry another code, and
/// adding BGN to EUR would print a number no ledger has. The graphs draw
/// EUR only, and `otherCurrencies` says what they left out.
///
/// "Per currency" means per CURRENCY, not per spelling: the phone's old
/// free-text «Валута» stored «EURO», and the owner's «Торове» read
/// «11 119,50 EUR и 10,00 EURO» (2026-11-01). Nothing on the server ever
/// rewrote those rows; the summary folds the spellings when it reads them
/// since agri-saas #2710 (2026-11-02). `CostCurrency.code` folds them here
/// too, adding cents to cents, for a summary from before that (a cached
/// one, or a server not yet deployed); after it, this is a no-op. Lev
/// stays lev, here and there. The list is agri-saas `EURO_SPELLINGS`, NOT
/// `canonicalCostCurrency`, which folds lev into EUR as well, for a rollup
/// that converts the amount at the peg; adding lev cents to euro cents
/// would be exactly the blend this refuses.
struct CostBreakdown: Equatable {
    /// The currency the graphs are drawn in.
    static let chartCurrency = "EUR"

    struct TypeGroup: Identifiable, Equatable {
        let category: CostCategory
        /// The list's rows of this type, newest first.
        let entries: [CostEntry]
        /// Sum per currency, EUR first.
        let totals: [Total]
        /// How many the type has, which the list may hold fewer of.
        let count: Int
        var id: CostCategory { category }
        /// What the graphs and the order use.
        var chartAmount: Double { totals.first { $0.currency == CostBreakdown.chartCurrency }?.double ?? 0 }

        /// «Показани 12 от 40 разхода.» when the list holds fewer of this
        /// type than it has; the totals above count them all.
        var shownNote: String? {
            entries.count < count ? "Показани \(entries.count) от " + Plural.bg(count, "разход", "разхода") + "." : nil
        }
    }

    struct Total: Equatable {
        let currency: String
        /// Cents.
        let minor: Int
        var amount: Decimal { Decimal(minor) / 100 }
        var double: Double { NSDecimalNumber(decimal: amount).doubleValue }
    }

    /// One bar segment: a type's EUR spending in one month.
    struct MonthAmount: Equatable, Identifiable {
        /// The first day of the month, at the phone's midnight.
        let month: Date
        let category: CostCategory
        /// Cents.
        let minor: Int
        var amount: Double { NSDecimalNumber(decimal: Decimal(minor) / 100).doubleValue }
        var id: String { "\(month.timeIntervalSince1970)-\(category.rawValue)" }
    }

    /// Every type the farm has, biggest first: what the dropdown offers.
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

    /// `chosen` empty is «Всички». `entries` are the rows on screen;
    /// `hidden` the ones swiped away and not yet sent.
    init(summary: CostSummary, entries: [CostEntry], chosen: Set<CostCategory> = [], hidden: [CostEntry] = []) {
        var byType: [TypeKey: Sum] = [:]
        for row in summary.byType {
            byType[TypeKey(category: row.category, currency: CostCurrency.code(row.currency)), default: Sum()]
                .add(row.totalMinor, row.count)
        }
        var byMonth: [MonthKey: Int] = [:]
        for row in summary.byTypeAndMonth {
            let currency = CostCurrency.code(row.currency)
            guard currency == Self.chartCurrency else { continue }
            byMonth[MonthKey(category: row.category, month: row.month), default: 0] += row.totalMinor
        }
        for gone in hidden {
            let minor = Self.minor(gone.amount.value)
            byType[TypeKey(category: gone.category, currency: gone.currencyCode), default: Sum()].add(-minor, -1)
            if gone.currencyCode == Self.chartCurrency {
                byMonth[MonthKey(category: gone.category, month: Self.monthKey(of: gone.incurredOn)), default: 0] -= minor
            }
        }

        let rows = Dictionary(grouping: entries, by: \.category)
        let categories = Set(byType.filter { $0.value.count > 0 }.map(\.key.category)).union(rows.keys)
        let all = Self.biggestFirst(categories.map { category in
            let totals = Self.ordered(byType.filter { $0.key.category == category && $0.value.count > 0 }
                .map { Total(currency: $0.key.currency, minor: $0.value.minor) })
            let entries = (rows[category] ?? []).sorted { $0.incurredOn > $1.incurredOn }
            let count = byType.filter { $0.key.category == category }.reduce(0) { $0 + $1.value.count }
            return TypeGroup(category: category, entries: entries, totals: totals, count: max(count, entries.count))
        })
        available = all.map(\.category)
        groups = chosen.isEmpty ? all : all.filter { chosen.contains($0.category) }

        var sums: [String: Int] = [:]
        for group in groups {
            for total in group.totals { sums[total.currency, default: 0] += total.minor }
        }
        totals = Self.ordered(sums.map { Total(currency: $0.key, minor: $0.value) })
        count = groups.reduce(0) { $0 + $1.count }
        otherCurrencies = totals.map(\.currency).filter { $0 != Self.chartCurrency }.sorted()

        let shown = Set(groups.map(\.category))
        months = byMonth
            .filter { shown.contains($0.key.category) && $0.value != 0 }
            .compactMap { key, minor in
                Self.month(key.month).map { MonthAmount(month: $0, category: key.category, minor: minor) }
            }
            .sorted { ($0.month, $0.category.label) < ($1.month, $1.category.label) }
    }

    /// The EUR the month graph adds up to: one month, or all of them.
    func chartTotal(in month: Date?) -> Total {
        Total(currency: Self.chartCurrency,
              minor: months.filter { month == nil || $0.month == month }.reduce(0) { $0 + $1.minor })
    }

    /// A summary month, `YYYY-MM`, as the 1st of that month at the PHONE's
    /// midnight: the calendar Swift Charts buckets `unit: .month` and
    /// places its axis marks in. A month string has no zone to misread;
    /// the old UTC instants put «авг» under September (2026-11-01).
    static func month(_ key: String, in calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// An expense's month as the summary writes it. `incurredOn` is a day
    /// the server stores as its UTC midnight and buckets with `to_char` in
    /// UTC, so it is read in UTC here too.
    static func monthKey(of date: Date) -> String {
        let parts = utc.dateComponents([.year, .month], from: date)
        let month = parts.month ?? 1
        return "\(parts.year ?? 0)-\(month < 10 ? "0" : "")\(month)"
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// An amount in cents, as the server's `(SUM("amount") * 100)::bigint`
    /// makes it. A `Decimal(14,2)` times 100 is whole, so nothing rounds.
    static func minor(_ amount: Decimal) -> Int {
        var exact = amount * 100
        var whole = Decimal()
        NSDecimalRound(&whole, &exact, 0, .plain)
        return NSDecimalNumber(decimal: whole).intValue
    }

    private struct TypeKey: Hashable {
        let category: CostCategory
        let currency: String
    }

    private struct MonthKey: Hashable {
        let category: CostCategory
        let month: String
    }

    private struct Sum {
        var minor = 0
        var count = 0
        mutating func add(_ minor: Int, _ count: Int) {
            self.minor += minor
            self.count += count
        }
    }

    /// EUR first, then the others by code.
    private static func ordered(_ totals: [Total]) -> [Total] {
        totals.sorted {
            ($0.currency == chartCurrency ? 0 : 1, $0.currency) < ($1.currency == chartCurrency ? 0 : 1, $1.currency)
        }
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

/// A cost's currency as a CODE rather than as typed: the euro's spellings are
/// one currency (agri-saas `EURO_SPELLINGS`: EUR, EURO, EUROS, €, E, and a
/// blank, which on an EUR-only farm is a missing label). Anything else keeps
/// its own uppercased code; nothing is converted here.
enum CostCurrency {
    static let euroSpellings: Set = ["EUR", "EURO", "EUROS", "€", "E", ""]

    static func code(_ stored: String?) -> String {
        let code = (stored ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return euroSpellings.contains(code) ? CostBreakdown.chartCurrency : code
    }
}

extension CostEntry {
    /// `currency` as one code per currency (`CostCurrency`): what is summed,
    /// grouped and shown.
    var currencyCode: String { CostCurrency.code(currency) }
}
