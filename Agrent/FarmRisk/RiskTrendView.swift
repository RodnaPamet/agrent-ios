import Charts
import SwiftUI

/// A parcel's greenness and moisture over the period chosen, under its «Риск»
/// reading (owner, 2026-11-07: "provide info based on a time period, like
/// the past 14 days"; #562): 14, 30 or 60 days, a line per index, and the
/// change in one sentence (`RiskTrendWords`).
///
/// A cloudy pass is a BREAK in the line, never a fall to 0: each run of clear
/// passes is its own series (`RiskTrendPoints`), and every pass is a dot so a
/// clear day between two cloudy ones still shows.
struct RiskTrendView: View {
    @Bindable var store: RiskTrendStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Период", selection: $store.days) {
                ForEach(RiskTrendAPI.periods, id: \.self) { days in
                    Text("\(days) дни").tag(days)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityInputLabels(A11y.spokenNames("Период", "Period"))
            content
        }
        // Per period, and only when it changed: a row scrolled back into view
        // does not ask again (`RiskTrendStore.loadedDays`).
        .task(id: store.days) { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let message):
            note(message)
        case .loaded(let history, _):
            if let empty = RiskTrendWords.empty(history) {
                note(empty)
            } else {
                chart(history)
                if let change = RiskTrendWords.change(history) {
                    Text(change)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if history.truncated {
                    note("Не всички снимки от периода бяха прочетени. Опитайте отново по-късно.")
                }
            }
        }
    }

    private func chart(_ history: ParcelRiskHistory) -> some View {
        let points = RiskTrendPoints.points(history)
        return Chart(points) { point in
            LineMark(x: .value("Дата", point.date), y: .value("Индекс", point.value),
                     series: .value("Отрязък", point.series))
                .foregroundStyle(by: .value("Показател", point.index.title))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Дата", point.date), y: .value("Индекс", point.value))
                .foregroundStyle(by: .value("Показател", point.index.title))
                .symbolSize(18)
        }
        .chartForegroundStyleScale([RiskTrendPoints.Index.ndvi.title: Palette.ChartSeries.colors[0],
                                    RiskTrendPoints.Index.ndmi.title: Palette.ChartSeries.colors[1]])
        // Fixed to the indices' working range, not fitted: a fitted axis
        // makes 0,70 → 0,68 look like a collapse. Below 0 only when NDMI is.
        .chartYScale(domain: RiskTrendPoints.domain(points))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(BgDate.dayMonthShort(date)).font(.caption2).axisLabelScaling()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                if let number = value.as(Double.self) {
                    AxisValueLabel {
                        Text(WeatherWords.number(number, places: 1)).font(.caption2).axisLabelScaling()
                    }
                }
            }
        }
        .frame(height: 160)
        // One stop: the sentence under it says what the lines say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Зеленина и влага за \(history.days) дни")
        .accessibilityValue(RiskTrendWords.change(history) ?? "")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The chart's points: one per index per clear pass, each run of clear
/// passes its own series so a cloudy pass breaks the line. Pure, so tests
/// pin the breaks.
enum RiskTrendPoints {
    enum Index: String, Sendable {
        case ndvi, ndmi
        var title: String { self == .ndvi ? "Зеленина" : "Влага" }
    }

    struct Point: Identifiable, Equatable, Sendable {
        let date: Date
        let index: Index
        let value: Double
        /// «ndvi-0», «ndvi-1» …: the run of clear passes this one belongs to.
        let series: String
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    static func points(_ history: ParcelRiskHistory) -> [Point] {
        var points: [Point] = []
        for (index, read) in [(Index.ndvi, \ParcelRiskHistory.Pass.ndvi), (.ndmi, \.ndmi)] {
            var run = 0
            var inRun = false
            for pass in history.passes {
                guard let date = pass.day else { continue }
                guard let value = pass[keyPath: read] else {
                    if inRun { run += 1 }
                    inRun = false
                    continue
                }
                inRun = true
                points.append(Point(date: date, index: index, value: value, series: "\(index.rawValue)-\(run)"))
            }
        }
        return points
    }

    /// 0…1, reaching below 0 only as far as a reading does.
    static func domain(_ points: [Point]) -> ClosedRange<Double> {
        let lowest = points.map(\.value).min() ?? 0
        return min(0, (lowest * 10).rounded(.down) / 10)...1
    }
}
