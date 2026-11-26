import Charts
import SwiftUI

/// The revamped Табло's three blocks (#671, owner 2026-11-17): "minimum text
/// and more graphs, including current weather and rainfall". Each shows a
/// chart and one number; the full sentence is for VoiceOver.

enum DashboardWords {
    static let noPlace = "Няма място за времето: разрешете местоположението или очертайте блок."
    static let rainSource = "Open-Meteo"
    static let ahead = "прогноза"

    /// «12°».
    static func degrees(_ c: Double) -> String { "\(Int(c.rounded()))°" }
    /// «4 м/с».
    static func wind(_ ms: Double) -> String { "\(Int(ms.rounded())) м/с" }
    /// «42 мм».
    static func millimetres(_ mm: Double) -> String { "\(Num.text((mm * 10).rounded() / 10)) мм" }
}

/// Now, and seven days: temperature, conditions and wind, then the days as a
/// strip of icons with highs and lows.
struct WeatherCard: View {
    let report: WeatherReport
    let place: WeatherPlace.Point?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(DashboardWords.degrees(report.now.temperatureC))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let symbol = report.now.symbolName {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.title)
                        .accessibilityHidden(true)
                }
                Spacer()
                Label(DashboardWords.wind(report.now.windMS), systemImage: "wind")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(nowSpoken)

            HStack(spacing: 0) {
                ForEach(report.days.prefix(7)) { day in
                    VStack(spacing: 4) {
                        Text(BgDate.weekdayShort(day.date))
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryText)
                        Image(systemName: day.symbolName ?? "cloud")
                            .symbolRenderingMode(.multicolor)
                            .font(.body)
                            .frame(height: 20)
                        Text(DashboardWords.degrees(day.highC)).font(.caption.weight(.semibold))
                        Text(DashboardWords.degrees(day.lowC)).font(.caption2).foregroundStyle(Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(daySpoken(day))
                }
            }
            WeatherAttribution(attribution: report.attribution)
        }
    }

    private var nowSpoken: String {
        A11y.sentence([
            "Сега \(DashboardWords.degrees(report.now.temperatureC))",
            "вятър \(DashboardWords.wind(report.now.windMS))",
            place?.isPhone == true ? "около вас" : "в стопанството",
        ])
    }

    private func daySpoken(_ day: WeatherReport.Day) -> String {
        A11y.sentence([
            BgDate.weekdayDay(day.date),
            "до \(DashboardWords.degrees(day.highC))",
            "от \(DashboardWords.degrees(day.lowC))",
            "вероятност за валеж \(Int((day.precipitationChance * 100).rounded())) процента",
        ])
    }
}

/// 30 days measured, 7 ahead lighter, and the 30-day total.
struct RainfallCard: View {
    let rainfall: Rainfall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardWords.millimetres(rainfall.measuredTotal))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Chart(rainfall.days) { day in
                BarMark(x: .value("Ден", day.date, unit: .day), y: .value("мм", day.millimetres))
                    .foregroundStyle(day.isForecast ? Palette.accent.opacity(0.35) : Palette.accent)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(BgDate.dayMonthShort(date)) }
                    }
                }
            }
            .frame(height: 120)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            Text(DashboardWords.rainSource)
                .font(.caption2)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var spoken: String {
        let ahead = rainfall.days.filter(\.isForecast).reduce(0) { $0 + $1.millimetres }
        return "Валежи за последните 30 дни \(DashboardWords.millimetres(rainfall.measuredTotal)). "
            + "Прогноза за следващите 7 дни \(DashboardWords.millimetres(ahead))."
    }
}

/// The farm's crops, two to a row: a 3-month line and the latest price.
struct CropPriceTiles: View {
    let tiles: [CropPriceTile]

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(tiles) { tile in
                CropPriceTileView(tile: tile)
            }
        }
    }
}

private struct CropPriceTileView: View {
    let tile: CropPriceTile

    private var lead: PriceSeries? { tile.state.value?.lead }
    /// «Пшеница», never `wheat`: the app's one crop vocabulary.
    private var name: String { CommodityName.canonical(tile.commodity.rawValue) ?? tile.commodity.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let lead, let latest = lead.points.last {
                Text(lead.headline(latest.price))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Chart(lead.points.compactMap { p in BgDate.parseISODay(p.date).map { (date: $0, price: p.price) } },
                      id: \.date) { point in
                    LineMark(x: .value("Ден", point.date), y: .value("Цена", point.price))
                        .foregroundStyle(Palette.accent)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 44)
            } else if tile.state.isFailed {
                Text("—").foregroundStyle(Palette.secondaryText)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        guard let lead, let latest = lead.points.last else { return name }
        return A11y.sentence([name, lead.headline(latest.price), SeriesSource.name(of: lead)])
    }
}
