import Foundation

/// «Всички»'s whole-farm block (owner, 2026-10-24): the lines a crop shows,
/// added up across the farm.
///
/// ── Weighted by the area each figure is per, never averaged ──
///
/// A plain average of three crops' «Разход / дка» would count a 20 дка
/// sunflower plot as much as 400 дка of wheat. So each rate is put back into
/// money over the area it was divided by, summed, and divided by the summed
/// area: value and margin over the yield-covered area (`areaDca`, what the
/// server divides them by), cost over the land the crop occupies
/// (`landDca`, agri-saas #1606).
///
/// ── Never two currencies in one figure ──
///
/// This product applies no exchange rate anywhere, and a cost need not share
/// the market price's currency (agri-saas #1614). So a figure is one line per
/// currency, and a farm whose crops all quote the same one sees one line.
///
/// ── What a figure leaves out, it says ──
///
/// A crop with no market price has no value per decare, and a total that
/// silently omits it reads as complete. Each figure names the crops it does
/// not include, as «Общо за стопанството» already does for the net worth.
struct FarmFigures: Equatable, Sendable {
    struct Rate: Equatable, Sendable, Identifiable {
        /// nil: the server's convention for "the farm's display currency",
        /// shown bare as on a crop's own line.
        let currency: String?
        let perDca: Double
        /// One of its crops' margins is an upper bound (`.atMost`), so the
        /// sum is one too.
        let atMost: Bool

        var id: String { currency ?? "" }
    }

    struct Figure: Equatable, Sendable {
        let rates: [Rate]
        /// Crops (server commodity values) with no such figure. Never shown
        /// as they are: the view names them through `CommodityName`
        /// (`CalculatorView.cropNames`), as the CI guard on `.commodity` asks.
        let without: [String]

        var isEmpty: Bool { rates.isEmpty }
    }

    /// The land the crops occupy, every crop counted.
    let areaDca: Double
    let value: Figure
    let cost: Figure
    let margin: Figure

    init(rows: [CalculatorRow]) {
        areaDca = rows.reduce(0) { $0 + $1.perArea.landDca }
        value = Self.figure(rows, rate: \.perArea.standingValuePerDca,
                            area: \.perArea.areaDca, currency: \.priceCurrency)
        cost = Self.figure(rows, rate: \.perArea.attributableCostPerDca,
                           area: \.perArea.landDca, currency: \.perArea.costCurrency)
        margin = Self.figure(rows, rate: \.perArea.marginPerDca,
                             area: \.perArea.areaDca, currency: \.priceCurrency)
    }

    /// The crops every shown figure leaves out, when that is one list — then
    /// it is said once. nil when they differ (each figure says its own) or
    /// when nothing is left out. A figure no crop has is not shown at all, so
    /// it does not count.
    static func commonOmission(netWorth: [[String]], figures: [Figure]) -> [String]? {
        let lists = netWorth + figures.filter { !$0.isEmpty }.map(\.without)
        guard let first = lists.first, !first.isEmpty else { return nil }
        let sorted = first.sorted()
        return lists.allSatisfy { $0.sorted() == sorted } ? first : nil
    }

    private static func figure(_ rows: [CalculatorRow],
                               rate: KeyPath<CalculatorRow, Double?>,
                               area: KeyPath<CalculatorRow, Double>,
                               currency: KeyPath<CalculatorRow, String?>) -> Figure {
        var money: [String?: (amount: Double, area: Double, atMost: Bool)] = [:]
        var without: [String] = []
        for row in rows {
            guard let perDca = row[keyPath: rate], row[keyPath: area] > 0 else {
                without.append(row.commodity)
                continue
            }
            let key = row[keyPath: currency]
            var sum = money[key] ?? (amount: 0, area: 0, atMost: false)
            sum.amount += perDca * row[keyPath: area]
            sum.area += row[keyPath: area]
            sum.atMost = sum.atMost || row.perArea.uncertainty == .atMost
            money[key] = sum
        }
        // A stable order — the bare line first, then by code — so the block
        // does not reshuffle between two reads of the same payload.
        let rates = money
            .map { Rate(currency: $0.key, perDca: $0.value.amount / $0.value.area, atMost: $0.value.atMost) }
            .sorted { ($0.currency ?? "") < ($1.currency ?? "") }
        return Figure(rates: rates, without: without)
    }
}

/// What the calculator shows: the farm and every crop, or one crop
/// (owner, 2026-10-24). Remembered per farm on this phone.
enum CalculatorScope: Hashable, Sendable {
    case all
    /// A server commodity value, as `CalculatorRow.commodity`.
    case crop(String)

    /// What `UserDefaults` holds. «all» cannot be a commodity: the server's
    /// are lowercase crop slugs.
    var stored: String {
        switch self {
        case .all: Self.allValue
        case .crop(let commodity): commodity
        }
    }

    init(stored: String?) {
        guard let stored, !stored.isEmpty, stored != Self.allValue else { self = .all; return }
        self = .crop(stored)
    }

    /// The scope to show for this payload. A remembered crop the farm no
    /// longer grows — or a farm with one crop, where «Всички» would repeat it
    /// — shows what there is rather than nothing.
    func resolved(for rows: [CalculatorRow]) -> CalculatorScope {
        if rows.count == 1, let only = rows.first { return .crop(only.commodity) }
        if case .crop(let commodity) = self, !rows.contains(where: { $0.commodity == commodity }) {
            return .all
        }
        return self
    }

    private static let allValue = "all"
}
