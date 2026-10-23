import Charts
import SwiftUI

/// One commodity's price: the number, how it moved, its line, and where it
/// comes from (#409).
///
/// Every commodity name on this screen comes from
/// `ChartableCommodity.label`, which resolves through `CommodityName` —
/// there is no path here that can print a raw slug, because `commodity` is
/// an enum rather than the server's string. See `TrendsStore.commodity`.
struct TrendsView: View {
    @State private var store = TrendsStore()

    var body: some View {
        RoutedStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controls
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // The page under the chart cards (`Surface.card`); without it they
        // sat on the system background, black in dark mode.
        .background(Palette.Surface.page)
        .inlineTitle("Тенденции")
        // «Затвори» only when the app menu presented this — see
        // `closeWhenPresentedFromMenu`. As a tab root it had one that did nothing.
        .closeWhenPresentedFromMenu()
        .task { if store.prices.value == nil { await store.loadPrices() } }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A Menu, not a segmented control: nine entries cannot share one
            // row, and the first thing a segmented control does when it runs
            // out of room is truncate — at which point Уреа and Ечемик are
            // both three letters.
            Menu {
                Section(titled: "Култури") {
                    ForEach(ChartableCommodity.allCases.filter { !$0.isInput }) { item in
                        button(for: item)
                    }
                }
                Section(titled: "Ресурси") {
                    ForEach(ChartableCommodity.allCases.filter(\.isInput)) { item in
                        button(for: item)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(store.commodity.label).font(.title3.weight(.semibold))
                    Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.primary)
                // A Menu's target is its label's bounds, and this label is an
                // unframed HStack — so the tappable area was the glyphs. It is
                // the control that chooses which commodity the whole screen is
                // about.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Стока: \(store.commodity.label)")
            .accessibilityHint("Избира стока за графиката")

            Picker("Период", selection: Binding(
                get: { store.range },
                set: { new in Task { await store.select(new) } }
            )) {
                ForEach(PriceRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func button(for item: ChartableCommodity) -> some View {
        Button {
            Task { await store.select(item) }
        } label: {
            if item == store.commodity {
                Label(item.label, systemImage: "checkmark")
            } else {
                Text(item.label)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.prices {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, minHeight: 240)

        case .failed(let message):
            ErrorState(message: message) { await store.loadPrices() }

        case .loaded:
            if let lead = store.lead, let latest = store.latest {
                priceCard(lead, latest: latest)
            } else {
                EmptyState(
                    "Няма котировки",
                    icon: "chart.line.uptrend.xyaxis",
                    message: "За избрания период няма налични цени за \(store.commodity.label)."
                )
                .frame(minHeight: 240)
            }
        }
    }

    // MARK: - The price

    /// ONE price, its line and one row (#409, owner 2026-10-23).
    ///
    /// The screen used to draw three lines and list every quotation the
    /// payload carried: twenty-four for wheat, each with a price, a day and an
    /// amber age, some in the EC feed's English. The owner asked for a clear
    /// price above the graph and at most one info row below it. Which price,
    /// and why the others are not here, is `Array.lead()`.
    private func priceCard(_ lead: PriceSeries, latest: PricePoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headline(lead, latest: latest)
            chart(lead)
            infoRow(lead, latest: latest)
        }
        .padding(14)
        .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 12))
    }

    /// «184,29 евро на тон», and how it moved over the range on screen.
    private func headline(_ lead: PriceSeries, latest: PricePoint) -> some View {
        let unit = SeriesVocabulary.priceUnit(unit: lead.unit, currency: lead.currency)
        let change = store.change
        return VStack(alignment: .leading, spacing: 4) {
            // Stacks at the accessibility sizes rather than truncating the
            // number, which is the one thing on the screen that must be whole.
            AdaptiveRow(spacing: 6) {
                Text(Num.text(latest.price))
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                Text(unit)
                    .font(.title3)
                    .foregroundStyle(Palette.secondaryText)
            }
            if let change {
                // An arrow and words, not red and green: a rise is good news
                // for wheat and bad news for diesel (`PeriodChange.text`).
                Text(change.text(over: store.range))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            "\(Num.text(latest.price)) \(unit)",
            change?.spoken(over: store.range),
        ]))
    }

    private func chart(_ lead: PriceSeries) -> some View {
        let points = store.leadPoints
        return Chart {
            ForEach(points.indices, id: \.self) { index in
                LineMark(
                    x: .value("Дата", points[index].day),
                    y: .value("Цена", points[index].price)
                )
                .foregroundStyle(Palette.accent)
                .interpolationMethod(.monotone)
            }
        }
        // Fitted to the data, not anchored at zero.
        //
        // Swift Charts includes zero by default, which for wheat at
        // 157–229 spent two thirds of the chart on empty space and
        // flattened a year of movement into a nearly straight line.
        // These are prices: the question is how they moved, and the
        // axis labels carry the absolute values for anyone who needs
        // them.
        .chartYScale(domain: yDomain(points.map(\.price)))
        .chartXAxis {
            // Three marks, not "as many as fit". `.automatic` counts
            // them against the axis width without knowing how wide a
            // Bulgarian month name gets — «септември» is nine
            // characters where «May» is three.
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                // Через BgDate, not a `.dateTime` format — the device
                // reports en_BG and would print English month names.
                // The CI guard rejects the other spelling outright.
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(BgDate.dayMonth(date))
                            .font(.caption2)
                            .axisLabelScaling()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                if let number = value.as(Double.self) {
                    AxisValueLabel {
                        Text(Num.text(number))
                            .font(.caption2)
                            .axisLabelScaling()
                    }
                }
            }
        }
        .frame(height: 220)
        // A chart is invisible to VoiceOver. The headline above says the
        // price and its change in words, so the chart says what it is and
        // where it starts and ends.
        .accessibilityLabel(chartSummary(points))
    }

    /// «Графика на цената за 1 година, от 176 до 184,29».
    private func chartSummary(_ points: [(day: Date, price: Double)]) -> String {
        guard let first = points.first, let last = points.last else { return "Графика на цената" }
        return "Графика на цената \(store.range.span), от \(Num.text(first.price)) до \(Num.text(last.price))"
    }

    /// The visible data's range with a margin, so the line is not drawn on
    /// the frame.
    private func yDomain(_ prices: [Double]) -> ClosedRange<Double> {
        guard let low = prices.min(), let high = prices.max() else { return 0...1 }
        guard high > low else { return (low - 1)...(high + 1) }
        let margin = (high - low) * 0.12
        return (low - margin)...(high + margin)
    }

    // MARK: - The one row under the chart

    /// «Средна за България · 27 юли», and «· преди 88 дни» in amber once the
    /// price is three weeks old (`Staleness.concerning`).
    ///
    /// TWO DIFFERENT AGES belong on this screen, and this is the market's:
    /// eighty-eight days for wheat's national average, under a payload that
    /// may be five minutes old. The phone's own fetch age is the banner's.
    private func infoRow(_ lead: PriceSeries, latest: PricePoint) -> some View {
        let source = SeriesSource.parts(of: lead)
        let day = latest.day.map(BgDate.dayMonth)
        let stale = store.staleDays.flatMap { $0 >= Staleness.concerning ? $0 : nil }
        let age = stale.map { "преди \(Plural.bg($0, "ден", "дни"))" }
        // One Text that wraps, not a row of them: a delivery point and an age
        // run past a phone's width, and an HStack would cut the age off — the
        // one part that is a warning.
        let text = ([source.joined(separator: " · ")] + [day, age].compactMap { $0 }).joined(separator: " · ")
        return Group {
            if stale != nil {
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.warning)
            } else {
                Text(text)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        // One element already, so its words are replaced rather than wrapped
        // in a second one. Built from the parts: VoiceOver reads «·» aloud as
        // "middle dot".
        .accessibilityLabel(A11y.sentence(source + [day.map { "към \($0)" }, age]))
    }
}
