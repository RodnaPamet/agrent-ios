import Charts
import SwiftUI

/// A parcel's greenness and moisture over the period chosen, under its «Риск»
/// reading (owner, 2026-11-07: "provide info based on a time period, like
/// the past 14 days"; #562): 14, 30 or 60 days, a line per index, and the
/// change in one sentence (`RiskTrendWords`).
///
/// A menu above it picks what is drawn (owner, 2026-11-16: "a dropdown to
/// choose between different metrics. One needed is rain"): the two indices
/// together or apart, and, where the parcel has a place, the rain per day in
/// л/м² and the day's highest and lowest temperature (`DailyWeatherStore`).
/// The choice is remembered, so a farmer who reads rain first sees rain
/// first on the next parcel too.
///
/// A cloudy pass is a BREAK in the line, never a fall to 0: each run of clear
/// passes is its own series (`RiskTrendPoints`), and every pass is a dot so a
/// clear day between two cloudy ones still shows.
///
/// The time axis spans the whole period, not just the passes in it: two
/// passes a day apart once filled the width and labelled every gridline
/// «7 ное» (owner's screenshot, 2026-11-16).
struct RiskTrendView: View {
    @Bindable var store: RiskTrendStore
    /// The rain and temperature, with the place to ask about; nil where the
    /// parcel has no outline, and the menu then offers the indices only.
    var weather: DailyWeatherStore?
    var place: (latitude: Double, longitude: Double)?

    @AppStorage("riskTrend.metric") private var metricRaw = RiskTrendMetric.indices.rawValue

    private var metrics: [RiskTrendMetric] {
        RiskTrendMetric.allCases.filter { !$0.isWeather || (weather != nil && place != nil) }
    }

    private var metric: RiskTrendMetric {
        let chosen = RiskTrendMetric(rawValue: metricRaw) ?? .indices
        return metrics.contains(chosen) ? chosen : .indices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Показател", selection: Binding(get: { metric }, set: { metricRaw = $0.rawValue })) {
                ForEach(metrics, id: \.self) { each in
                    Text(each.title).tag(each)
                }
            }
            .pickerStyle(.menu)
            .tint(Palette.accent)
            .accessibilityInputLabels(A11y.spokenNames("Показател", "Metric"))
            Picker("Период", selection: $store.days) {
                ForEach(RiskTrendAPI.periods, id: \.self) { days in
                    Text("\(days) дни").tag(days)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityInputLabels(A11y.spokenNames("Период", "Period"))
            if metric.isWeather, let weather {
                weatherContent(weather)
            } else {
                content
            }
        }
        // Per period, and only when it changed: a row scrolled back into view
        // does not ask again (`RiskTrendStore.loadedDays`).
        .task(id: store.days) { await store.load() }
        // Open-Meteo only once a weather metric is chosen: the indices alone
        // need no third party.
        .task(id: "\(metric.rawValue)-\(store.days)") {
            guard metric.isWeather, let weather, let place else { return }
            await weather.load(days: store.days, latitude: place.latitude, longitude: place.longitude)
        }
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
                if let change = RiskTrendWords.change(history, only: metric.index) {
                    sentence(change)
                }
                if history.truncated {
                    note("Не всички снимки от периода бяха прочетени. Опитайте отново по-късно.")
                }
            }
        }
    }

    @ViewBuilder
    private func weatherContent(_ weather: DailyWeatherStore) -> some View {
        switch weather.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let message):
            note(message)
        case .loaded(let days, _):
            if days.isEmpty {
                note("Няма данни за времето за този период.")
            } else if metric == .rain {
                rainChart(days)
                if let words = DailyWeatherWords.rain(days, period: store.days) { sentence(words) }
            } else {
                temperatureChart(days)
                if let words = DailyWeatherWords.temperature(days) { sentence(words) }
            }
            Text("Данни: Open-Meteo, за средата на парцела.")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private func chart(_ history: ParcelRiskHistory) -> some View {
        let points = RiskTrendPoints.points(history).filter { metric.index == nil || $0.index == metric.index }
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
        .chartXScale(domain: RiskTrendPoints.period(days: history.days))
        .chartXAxis { dateAxis }
        .chartYAxis { valueAxis(places: 1) }
        .frame(height: 160)
        // One stop: the sentence under it says what the lines say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) за \(history.days) дни")
        .accessibilityValue(RiskTrendWords.change(history, only: metric.index) ?? "")
    }

    private func rainChart(_ days: [DailyWeather]) -> some View {
        Chart(days.filter { $0.rain != nil }) { day in
            BarMark(x: .value("Дата", day.date, unit: .day), y: .value("л/м²", day.rain ?? 0))
                .foregroundStyle(Palette.ChartSeries.colors[1])
        }
        .chartXScale(domain: RiskTrendPoints.period(days: store.days))
        .chartXAxis { dateAxis }
        .chartYAxis { valueAxis(places: 0) }
        .frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Валежи за \(store.days) дни")
        .accessibilityValue(DailyWeatherWords.rain(days, period: store.days) ?? "")
    }

    private func temperatureChart(_ days: [DailyWeather]) -> some View {
        Chart {
            ForEach(days) { day in
                if let high = day.high {
                    LineMark(x: .value("Дата", day.date, unit: .day), y: .value("°C", high),
                             series: .value("Ред", "high"))
                        .foregroundStyle(by: .value("Показател", "Най-висока"))
                }
                if let low = day.low {
                    LineMark(x: .value("Дата", day.date, unit: .day), y: .value("°C", low),
                             series: .value("Ред", "low"))
                        .foregroundStyle(by: .value("Показател", "Най-ниска"))
                }
            }
            // The frost line: a night under it is the one to look for.
            RuleMark(y: .value("°C", 0))
                .foregroundStyle(Palette.secondaryText)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartForegroundStyleScale(["Най-висока": Palette.ChartSeries.colors[0],
                                    "Най-ниска": Palette.ChartSeries.colors[1]])
        .chartXScale(domain: RiskTrendPoints.period(days: store.days))
        .chartXAxis { dateAxis }
        .chartYAxis { valueAxis(places: 0) }
        .frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Температура за \(store.days) дни")
        .accessibilityValue(DailyWeatherWords.temperature(days) ?? "")
    }

    private var dateAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            if let date = value.as(Date.self) {
                AxisValueLabel {
                    Text(BgDate.dayMonthShort(date)).font(.caption2).axisLabelScaling()
                }
            }
        }
    }

    private func valueAxis(places: Int) -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            if let number = value.as(Double.self) {
                AxisValueLabel {
                    Text(WeatherWords.number(number, places: places)).font(.caption2).axisLabelScaling()
                }
            }
        }
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the chart draws (owner, 2026-11-16).
enum RiskTrendMetric: String, CaseIterable, Sendable {
    case indices, ndvi, ndmi, rain, temperature

    var title: String {
        switch self {
        case .indices: "Зеленина и влага"
        case .ndvi: "Зеленина (NDVI)"
        case .ndmi: "Влага (NDMI)"
        case .rain: "Валежи, л/м²"
        case .temperature: "Температура, °C"
        }
    }

    var isWeather: Bool { self == .rain || self == .temperature }

    /// The one index drawn; nil for both, or for a weather metric.
    var index: RiskTrendPoints.Index? {
        switch self {
        case .ndvi: .ndvi
        case .ndmi: .ndmi
        default: nil
        }
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

    /// The whole period up to today, so the axis is the period chosen and
    /// not the stretch the passes happen to cover.
    static func period(days: Int, now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -days, to: today) ?? today
        return start...today
    }

    /// 0…1, reaching below 0 only as far as a reading does.
    static func domain(_ points: [Point]) -> ClosedRange<Double> {
        let lowest = points.map(\.value).min() ?? 0
        return min(0, (lowest * 10).rounded(.down) / 10)...1
    }
}
