import Charts
import SwiftUI

/// «Времето» for a block (#551, owner 2026-11-06): "show the winds and the
/// cyclones dynamics", from Apple's WeatherKit (the owner's choice over a
/// weather map).
///
/// ── What it shows, in this order ──
///
/// 1. «Сега»: the wind in m/s and where it comes from, its gusts, the
///    pressure and where it is heading, in words: falling usually means a
///    low (a cyclone) is coming in, rising a high.
/// 2. Apple's alerts for the place, where it has any.
/// 3. 48 hours of wind and gusts, then of pressure: a dip in the pressure
///    line IS the low passing, which is the "dynamics" a point forecast can
///    show without a map.
/// 4. Ten days.
/// 5. Apple Weather's mark and its sources' link, which the service
///    requires beside its data.
struct WeatherSheet: View {
    /// The block's name, for the title row.
    let place: String
    let latitude: Double
    let longitude: Double
    var source: any WeatherSource = WeatherSources.current

    @State private var state: LoadState<WeatherReport> = .loading
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            content
                .inlineTitle("Времето")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
                .task { await load() }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await source.report(latitude: latitude, longitude: longitude), .fresh)
        } catch {
            // WeatherKit's errors are English, and the owner's rule is no
            // English prose: one Bulgarian sentence, and «Опитай пак».
            state = .failed("Времето не може да се зареди в момента.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded(let report, _):
            List {
                Group {
                    Text(place)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .listRowSeparator(.hidden)
                    nowSection(report)
                    if !report.alerts.isEmpty { alertsSection(report.alerts) }
                    if !report.hours.isEmpty {
                        windChart(report.hours)
                        pressureChart(report.hours)
                    }
                    if !report.days.isEmpty { daysSection(report.days) }
                    attribution(report.attribution)
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await load() } }
        }
    }

    // MARK: - Now

    @ViewBuilder
    private func nowSection(_ report: WeatherReport) -> some View {
        let now = report.now
        SectionTitle("Сега")
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            windArrow(now.windFromDegrees)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(WeatherWords.speed(now.windMS)) от \(WeatherWords.compass(now.windFromDegrees))")
                    .font(.title3.weight(.semibold))
                if let gust = now.gustMS {
                    Text("Пориви до \(WeatherWords.speed(gust))")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            "Вятър \(WeatherWords.speed(now.windMS)) от \(WeatherWords.compassSpoken(now.windFromDegrees))",
            now.gustMS.map { "пориви до \(WeatherWords.speed($0))" },
        ]))
        VStack(alignment: .leading, spacing: 4) {
            Text("Налягане \(WeatherWords.pressure(now.pressureHPa))")
                .font(.headline)
            if let words = WeatherWords.trend(now.pressureTrend) {
                Text(words)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let change = WeatherWords.pressureChange(report.hours) {
                Text("Прогноза: \(WeatherWords.changeText(change))")
                    .font(.subheadline)
                    .foregroundStyle(WeatherWords.isSharpFall(change) ? Palette.warning : Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        Text("\(WeatherWords.temperature(now.temperatureC)), влажност \(WeatherWords.percent(now.humidity))")
            .font(.subheadline)
            .foregroundStyle(Palette.secondaryText)
    }

    /// Where the wind blows TO, as the eye reads a wind arrow. Spoken in
    /// words beside it, so hidden.
    private func windArrow(_ fromDegrees: Double) -> some View {
        Image(systemName: "arrow.up")
            .font(.title2)
            .foregroundStyle(Palette.accent)
            .rotationEffect(.degrees(fromDegrees + 180))
            .accessibilityHidden(true)
    }

    // MARK: - Alerts

    @ViewBuilder
    private func alertsSection(_ alerts: [WeatherReport.Alert]) -> some View {
        SectionTitle("Предупреждения")
        ForEach(alerts) { alert in
            VStack(alignment: .leading, spacing: 4) {
                Text(WeatherWords.alertTitle(alert.summary))
                    .font(.headline)
                    .foregroundStyle(Palette.warning)
                MetaRow {
                    Text(alert.severity)
                    MetaSeparator()
                    Text(alert.source)
                }
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                if let url = alert.detailsURL {
                    Link("Подробности", destination: url)
                        .font(.footnote)
                        .accessibilityInputLabels(A11y.spokenNames("Подробности", "Details"))
                }
            }
        }
    }

    // MARK: - 48 hours

    @ViewBuilder
    private func windChart(_ hours: [WeatherReport.Hour]) -> some View {
        SectionTitle("Вятър, 48 часа")
        Chart {
            ForEach(hours) { hour in
                LineMark(x: .value("Дата", hour.date), y: .value("м/с", hour.windMS),
                         series: .value("Вид", "Вятър"))
                    .foregroundStyle(by: .value("Вид", "Вятър"))
                    .interpolationMethod(.monotone)
                if let gust = hour.gustMS {
                    LineMark(x: .value("Дата", hour.date), y: .value("м/с", gust),
                             series: .value("Вид", "Пориви"))
                        .foregroundStyle(by: .value("Вид", "Пориви"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(["Вятър": Palette.ChartSeries.colors[0], "Пориви": Palette.ChartSeries.colors[1]])
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(BgDate.hourMark(date)).font(.caption2).axisLabelScaling()
                    }
                }
            }
        }
        .chartYAxis { numberAxis }
        .frame(height: 180)
        .accessibilityLabel(windSummary(hours))
    }

    @ViewBuilder
    private func pressureChart(_ hours: [WeatherReport.Hour]) -> some View {
        SectionTitle("Налягане, 48 часа")
        let values = hours.map(\.pressureHPa)
        Chart {
            ForEach(hours) { hour in
                LineMark(x: .value("Дата", hour.date), y: .value("hPa", hour.pressureHPa))
                    .foregroundStyle(Palette.accent)
                    .interpolationMethod(.monotone)
            }
        }
        // Fitted, not from zero: a low is a few hPa, invisible on 0…1030.
        .chartYScale(domain: ((values.min() ?? 1000) - 2)...((values.max() ?? 1030) + 2))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(BgDate.hourMark(date)).font(.caption2).axisLabelScaling()
                    }
                }
            }
        }
        .chartYAxis { numberAxis }
        .frame(height: 160)
        .accessibilityLabel(pressureSummary(hours))
    }

    private var numberAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            if let number = value.as(Double.self) {
                AxisValueLabel {
                    Text(Num.text(number)).font(.caption2).axisLabelScaling()
                }
            }
        }
    }

    /// «Вятър през следващите 48 часа: от 3 до 10,2 м/с, пориви до 18 м/с».
    private func windSummary(_ hours: [WeatherReport.Hour]) -> String {
        let winds = hours.map(\.windMS)
        let gust = hours.compactMap(\.gustMS).max()
        return A11y.sentence([
            "Вятър през следващите 48 часа: от \(WeatherWords.speed(winds.min() ?? 0)) до \(WeatherWords.speed(winds.max() ?? 0))",
            gust.map { "пориви до \(WeatherWords.speed($0))" },
        ])
    }

    /// «Налягане през следващите 48 часа: от 1016 до 1005 hPa, най-ниско 1005».
    private func pressureSummary(_ hours: [WeatherReport.Hour]) -> String {
        let values = hours.map(\.pressureHPa)
        guard let first = values.first, let last = values.last else { return "Налягане" }
        return A11y.sentence([
            "Налягане през следващите 48 часа: от \(WeatherWords.pressure(first)) до \(WeatherWords.pressure(last))",
            values.min().map { "най-ниско \(WeatherWords.pressure($0))" },
        ])
    }

    // MARK: - Ten days

    @ViewBuilder
    private func daysSection(_ days: [WeatherReport.Day]) -> some View {
        SectionTitle("10 дни")
        ForEach(days) { day in
            HStack(alignment: .firstTextBaseline) {
                Text(BgDate.weekdayDay(day.date))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(WeatherWords.speed(day.windMS)) \(WeatherWords.compass(day.windFromDegrees))")
                    .foregroundStyle(Palette.secondaryText)
                Text("\(WeatherWords.temperature(day.highC)) / \(WeatherWords.temperature(day.lowC))")
                    .monospacedDigit()
            }
            .font(.subheadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.sentence([
                BgDate.weekdayDay(day.date),
                "вятър \(WeatherWords.speed(day.windMS)) от \(WeatherWords.compassSpoken(day.windFromDegrees))",
                "до \(WeatherWords.temperature(day.highC)), от \(WeatherWords.temperature(day.lowC))",
                "вероятност за валежи \(WeatherWords.percent(day.precipitationChance))",
            ]))
        }
    }

    // MARK: - Attribution

    /// Apple Weather's mark and the link to its sources: required by the
    /// service beside anything shown from it.
    @ViewBuilder
    private func attribution(_ attribution: WeatherReport.Attribution?) -> some View {
        if let attribution {
            VStack(alignment: .leading, spacing: 6) {
                if let mark = scheme == .dark ? attribution.markDarkURL : attribution.markLightURL {
                    AsyncImage(url: mark) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(attribution.serviceName).font(.footnote)
                    }
                    .frame(height: 14)
                    .accessibilityLabel(attribution.serviceName)
                }
                if let legal = attribution.legalPageURL {
                    Link("Източници на данните", destination: legal)
                        .font(.footnote)
                        .accessibilityInputLabels(A11y.spokenNames("Източници на данните", "Data sources"))
                }
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        }
    }
}
