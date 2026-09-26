import Charts
import SwiftUI

/// Price history, one chart per unit-and-currency.
private extension View {
    /// Axis labels stop growing at `.large`.
    ///
    /// ── Measured, not assumed ──
    ///
    /// At AX3 the x axis rendered «1 октом18нуар1апр…» — three date
    /// labels overlapping into one unreadable string. A chart axis has a
    /// fixed width that text does not get to negotiate with, so labels
    /// that scale without limit do not become more readable, they become
    /// illegible in a different way.
    ///
    /// ── Why this is not a loss of accessibility ──
    ///
    /// The chart was never the accessible surface. It is one opaque
    /// element to VoiceOver by construction, and the legend beneath it
    /// carries every series' name, latest price, date and age AS TEXT —
    /// which does scale to AX5, and which is the path somebody reading at
    /// AX3 is actually using. Capping the axis makes the chart remain a
    /// picture of the shape; the numbers live below it and always did.
    ///
    /// Clamping the whole screen would be the wrong fix: it would shrink
    /// the legend too, which is the part that must grow.
    func axisLabelScaling() -> some View {
        dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// Every commodity name on this screen comes from
/// `ChartableCommodity.label`, which resolves through `CommodityName` —
/// there is no path here that can print a raw slug, because `commodity` is
/// an enum rather than the server's string. See `TrendsStore.commodity`.
struct TrendsView: View {
    @State private var store = TrendsStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // TWO DIFFERENT AGES, and both belong on this screen.
                //
                // This one is how long ago THIS PHONE fetched. The orange
                // line under each series is how long ago the MARKET was
                // observed — eighty-four days for the reference series,
                // against a payload that may be five minutes old.
                //
                // Every other screen in the app shows this banner and these
                // two did not, which an offline run made obvious: the
                // charts rendered perfectly from cache with nothing saying
                // the data had not been refreshed. On the one screen whose
                // whole subject is how current a number is, that was the
                // worst place to have left it out.
                controls
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .inlineTitle("Тенденции")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Затвори") { dismiss() }
            }
        }
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
                Section("Култури") {
                    ForEach(ChartableCommodity.allCases.filter { !$0.isInput }) { item in
                        button(for: item)
                    }
                }
                Section("Ресурси") {
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
            let groups = store.groups
            if groups.isEmpty {
                EmptyState(
                    "Няма котировки",
                    icon: "chart.line.uptrend.xyaxis",
                    message: "За избрания период няма налични цени за \(store.commodity.label)."
                )
                .frame(minHeight: 240)
            } else {
                ForEach(groups) { group in
                    chartCard(group)
                }
            }
        }
    }

    // MARK: - One chart

    /// One unit and one currency per card.
    ///
    /// Wheat returns USD per metric ton from Alpha Vantage alongside EUR/t
    /// from the EC feed. On a shared axis the gap between them draws as a
    /// price movement when it is an exchange rate — so they get separate
    /// cards and there is no axis on which they can be compared by eye.
    private func chartCard(_ group: SeriesGroup) -> some View {
        let visible = group.series.filter(store.isVisible)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(SeriesVocabulary.unitHeading(unit: group.unit, currency: group.currency))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if group.series.count > visible.count {
                    Text("\(visible.count) от \(group.series.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Chart {
                ForEach(visible) { series in
                    ForEach(series.points.indices, id: \.self) { index in
                        let point = series.points[index]
                        if let day = point.day {
                            LineMark(
                                x: .value("Дата", day),
                                y: .value("Цена", point.price)
                            )
                            .foregroundStyle(by: .value("Серия", series.id))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            // Explicit scale, so the line and its legend dot are the same
            // colour. Left to the automatic scale they were not, and a
            // legend that mislabels which line is which is worse than none.
            .chartForegroundStyleScale(
                domain: visible.map(\.id),
                range: visible.map { store.colour(for: $0, in: group) }
            )
            .chartLegend(.hidden)
            // Fitted to the data, not anchored at zero.
            //
            // Swift Charts includes zero by default, which for wheat at
            // 157–229 spent two thirds of the chart on empty space and
            // flattened a year of movement into a nearly straight line.
            // These are prices: the question is how they moved, and the
            // axis labels carry the absolute values for anyone who needs
            // them.
            .chartYScale(domain: yDomain(visible))
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
            // A chart is invisible to VoiceOver. The legend below carries
            // every series' latest value and age as text, so the screen is
            // not chart-only — but say what this is rather than leaving an
            // unlabelled rectangle.
            .accessibilityLabel("Графика на цените, \(group.unit), \(group.currency)")
            .accessibilityHint("Стойностите са изброени под графиката")

            ForEach(group.series) { series in
                legendRow(series, in: group)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The visible data's range with a margin, so no line is drawn on the
    /// frame. Falls back to the automatic scale when there is nothing to
    /// measure.
    private func yDomain(_ series: [PriceSeries]) -> ClosedRange<Double> {
        let prices = series.flatMap { $0.points.map(\.price) }
        guard let low = prices.min(), let high = prices.max() else { return 0...1 }
        guard high > low else { return (low - 1)...(high + 1) }
        let margin = (high - low) * 0.12
        return (low - margin)...(high + margin)
    }

    // MARK: - Legend

    /// Each series as a row: what it is, its latest price, and how old.
    private func legendRow(_ series: PriceSeries, in group: SeriesGroup) -> some View {
        let visible = store.isVisible(series)
        let latest = store.latest(series)
        let stale = store.staleDays(series)

        return Button {
            store.toggle(series)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(visible ? store.colour(for: series, in: group) : Color(.tertiaryLabel))
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(seriesTitle(series))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(visible ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let latest, let day = latest.day {
                        HStack(spacing: 6) {
                            Text("\(Num.text(latest.price)) \(group.currency)")
                                .font(.footnote.weight(.semibold))
                            Text(BgDate.dayMonth(day))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    staleness(stale)

                    if let count = latest?.count {
                        // Only on listings-derived series, where it says how
                        // many distinct farms the number came from. A price
                        // from one seller is not a market.
                        Text("от \(Plural.bg(count, "оферта", "оферти"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(visible ? [.isButton, .isSelected] : .isButton)
        // `combine` concatenates the price, the age and the series name into
        // one phrase, which is the only thing Voice Control would accept. The
        // series title is what is printed and what somebody would say.
        .accessibilityInputLabels([seriesTitle(series)])
        .accessibilityHint(visible ? "Скрива тази серия" : "Показва тази серия")
    }

    private func seriesTitle(_ series: PriceSeries) -> String {
        var parts = [SeriesVocabulary.region(series.region)]
        if let stage = SeriesVocabulary.stage(series.stage) { parts.append(stage) }
        if let label = series.label, !label.isEmpty { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    /// How old the last observation is, in words.
    ///
    /// Measured server-side to server-side — see `Staleness`. Said out loud
    /// past three weeks because the real data needs it: wheat's reference
    /// series was eighty-three days behind the payload that carried it,
    /// under a chart that looked entirely current.
    @ViewBuilder
    private func staleness(_ days: Int?) -> some View {
        if let days {
            if days >= Staleness.concerning {
                Label(
                    "Последно наблюдение преди \(Plural.bg(days, "ден", "дни"))",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Няма дата на последно наблюдение.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
