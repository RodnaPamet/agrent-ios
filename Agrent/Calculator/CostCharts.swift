import Charts
import SwiftUI

/// «Разходи»'s graphs (#500, owner 2026-11-01): the chosen expenses by type,
/// and by month split by type. EUR only (`CostBreakdown.chartCurrency`). A
/// type's own month graph, shown when it was opened, was taken out the same
/// day at the owner's word: opened, a type shows its rows.
///
/// Each is ONE element to VoiceOver, read as the numbers it draws, as the
/// dashboard's charts are: a bar is a picture, and its figure is the point.
///
/// A type has ONE colour in both (`CostChartColours`): the six biggest
/// take the design system's six series colours in order, the rest share the
/// muted one as «Останали».
enum CostChartColours {
    static let restLabel = "Останали"

    /// `order` is every shown type, biggest first.
    static func colour(_ category: CostCategory, in order: [CostCategory]) -> Color {
        guard let index = order.firstIndex(of: category), index < Palette.ChartSeries.colors.count else {
            return Palette.ChartSeries.rest
        }
        return Palette.ChartSeries.colors[index]
    }

    static func isColoured(_ category: CostCategory, in order: [CostCategory]) -> Bool {
        (order.firstIndex(of: category) ?? .max) < Palette.ChartSeries.colors.count
    }
}

/// One bar per type, biggest first, each with its amount at its end: the
/// chosen expenses' types, or one month's when the month graph's dropdown
/// picks a month.
struct CostTypeTotalsChart: View {
    struct Bar: Identifiable, Equatable {
        let category: CostCategory
        let amount: Double
        var id: CostCategory { category }
    }

    let bars: [Bar]
    /// Every shown type, biggest first: the colours' order, so a type is the
    /// same colour here as in the month graph.
    let order: [CostCategory]
    /// What VoiceOver hears before the figures.
    var spokenTitle = "Разходи по вид, в евро"

    @ScaledMetric(relativeTo: .body) private var barRoom: CGFloat = 34

    private var shown: [Bar] { bars.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount } }

    var body: some View {
        Chart(shown) { bar in
            BarMark(x: .value("Сума", bar.amount), y: .value("Вид", bar.category.label))
                .foregroundStyle(CostChartColours.colour(bar.category, in: order))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(Money.text(bar.amount, nil))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                }
        }
        // The names are the axis: wide enough to read whole, never cut.
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.caption).axisLabelScaling()
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        // Room at the end for the longest amount.
        .chartXScale(domain: 0...((shown.map(\.amount).max() ?? 1) * 1.35))
        .frame(height: barRoom * CGFloat(max(shown.count, 1)) + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([spokenTitle]
            + shown.map { "\($0.category.label) \(Money.text($0.amount, CostBreakdown.chartCurrency))" }))
    }
}

/// One bar per month, oldest first; split by type when there is more than one.
///
/// Six types get the design system's six series colours, biggest first; any
/// past the sixth share the muted one as «Останали». The legend names them,
/// and the spoken summary gives each month's total.
struct CostMonthsChart: View {
    let months: [CostBreakdown.MonthAmount]
    /// Every shown type, biggest first: the colours' order, so a type is the
    /// same colour here as in the other graphs, opened alone or not.
    let order: [CostCategory]

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 180

    private var coloured: [CostCategory] { order.filter { CostChartColours.isColoured($0, in: order) } }

    private func series(_ category: CostCategory) -> String {
        coloured.contains(category) ? category.label : CostChartColours.restLabel
    }

    /// The one type drawn, when only one is.
    private var only: CostCategory? {
        let present = Set(months.map(\.category))
        return present.count == 1 ? present.first : nil
    }

    private var monthTotals: [(month: Date, amount: Double)] {
        Dictionary(grouping: months, by: \.month)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        let single = only != nil
        Chart(months) { item in
            BarMark(x: .value("Месец", item.month, unit: .month),
                    y: .value("Сума", item.amount))
                .foregroundStyle(by: .value("Вид", single ? item.category.label : series(item.category)))
        }
        .chartForegroundStyleScale(domain: colourDomain(single), range: colourRange(single))
        .chartLegend(single ? .hidden : .visible)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(BgDate.monthShort(date)).font(.caption2).axisLabelScaling()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                if let amount = value.as(Double.self) {
                    AxisValueLabel {
                        Text(amount.formatted(.number.notation(.compactName).locale(BgDate.locale)))
                            .font(.caption2).axisLabelScaling()
                    }
                }
            }
        }
        .frame(height: min(height, 320))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(["Разходи по месеци, в евро"]
            + monthTotals.map { "\(BgDate.monthYear($0.month)) \(Money.text($0.amount, CostBreakdown.chartCurrency))" }))
    }

    private func colourDomain(_ single: Bool) -> [String] {
        if let only { return [only.label] }
        let present = Set(months.map(\.category))
        var domain = coloured.filter(present.contains).map(\.label)
        if present.contains(where: { !coloured.contains($0) }) { domain.append(CostChartColours.restLabel) }
        return domain
    }

    private func colourRange(_ single: Bool) -> [Color] {
        if let only { return [CostChartColours.colour(only, in: order)] }
        let present = Set(months.map(\.category))
        var range = coloured.filter(present.contains).map { CostChartColours.colour($0, in: order) }
        if present.contains(where: { !coloured.contains($0) }) { range.append(Palette.ChartSeries.rest) }
        return range
    }
}
