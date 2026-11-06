import CoreLocation
import Foundation
import WeatherKit

/// Where a block's weather comes from (#551): Apple's WeatherKit, chosen by
/// the owner over a weather map (2026-11-06). A protocol so A11yShots draws
/// the sheet from a fixture and no test ever asks Apple.
protocol WeatherSource: Sendable {
    func report(latitude: Double, longitude: Double) async throws -> WeatherReport
}

enum WeatherSources {
    /// The fixture under the UI test seam; Apple's service otherwise.
    static var current: any WeatherSource {
        #if DEBUG
        if UITestSeam.isActive { return FixtureWeatherSource() }
        #endif
        return AppleWeatherSource()
    }
}

/// WeatherKit, on the device. 500 000 calls a month come with the developer
/// membership; one sheet opening is one call (four data sets in one
/// request), plus the attribution, which WeatherKit caches.
///
/// ── What leaves the phone ──
///
/// The BLOCK's centre, not the device's position: the farm's own map
/// coordinate goes to Apple's weather service, the person's location never
/// does (`PrivacyManifestTests`).
struct AppleWeatherSource: WeatherSource {
    func report(latitude: Double, longitude: Double) async throws -> WeatherReport {
        let service = WeatherService()
        let place = CLLocation(latitude: latitude, longitude: longitude)
        let start = Date()
        let end = start.addingTimeInterval(48 * 3600)
        let (current, hourly, daily, alerts) = try await service.weather(
            for: place,
            including: .current, .hourly(startDate: start, endDate: end), .daily, .alerts)
        let attribution = try? await service.attribution
        return WeatherReport(
            now: .init(
                temperatureC: current.temperature.converted(to: .celsius).value,
                windMS: current.wind.speed.converted(to: .metersPerSecond).value,
                gustMS: current.wind.gust?.converted(to: .metersPerSecond).value,
                windFromDegrees: current.wind.direction.converted(to: .degrees).value,
                pressureHPa: current.pressure.converted(to: .hectopascals).value,
                pressureTrend: Self.trend(current.pressureTrend),
                humidity: current.humidity),
            hours: hourly.forecast.map {
                .init(date: $0.date,
                      windMS: $0.wind.speed.converted(to: .metersPerSecond).value,
                      gustMS: $0.wind.gust?.converted(to: .metersPerSecond).value,
                      windFromDegrees: $0.wind.direction.converted(to: .degrees).value,
                      pressureHPa: $0.pressure.converted(to: .hectopascals).value,
                      precipitationChance: $0.precipitationChance)
            },
            days: daily.forecast.map {
                .init(date: $0.date,
                      highC: $0.highTemperature.converted(to: .celsius).value,
                      lowC: $0.lowTemperature.converted(to: .celsius).value,
                      windMS: $0.wind.speed.converted(to: .metersPerSecond).value,
                      windFromDegrees: $0.wind.direction.converted(to: .degrees).value,
                      precipitationChance: $0.precipitationChance)
            },
            alerts: (alerts ?? []).map {
                .init(summary: $0.summary, severity: Self.severity($0.severity),
                      source: $0.source, detailsURL: $0.detailsURL)
            },
            attribution: attribution.map {
                .init(markLightURL: $0.combinedMarkLightURL, markDarkURL: $0.combinedMarkDarkURL,
                      legalPageURL: $0.legalPageURL, serviceName: $0.serviceName)
            })
    }

    /// The level in Bulgarian; WeatherKit's own `description` is English.
    private static func severity(_ severity: WeatherSeverity) -> String {
        switch severity {
        case .minor: "Слабо"
        case .moderate: "Умерено"
        case .severe: "Сериозно"
        case .extreme: "Изключително опасно"
        default: "Предупреждение"
        }
    }

    private static func trend(_ trend: WeatherKit.PressureTrend) -> WeatherReport.PressureTrend {
        switch trend {
        case .rising: .rising
        case .falling: .falling
        case .steady: .steady
        @unknown default: .unknown
        }
    }
}

#if DEBUG
/// A synthetic report for A11yShots: a low coming in, pressure falling
/// 9 hPa over the day and the wind rising from the south-west. Invented.
struct FixtureWeatherSource: WeatherSource {
    func report(latitude: Double, longitude: Double) async throws -> WeatherReport {
        let start = Calendar.current.date(bySetting: .minute, value: 0, of: Date()) ?? Date()
        var hours: [WeatherReport.Hour] = []
        for i in 0..<48 {
            let t = Double(i)
            let rising: Double = min(t, 24)
            let wind: Double = 3 + rising * 0.3
            let gust: Double = 6 + rising * 0.5
            let pressure: Double = 1016 - min(t, 30) * 0.375
            let rain: Double = min(t / 30, 0.9)
            hours.append(.init(date: start.addingTimeInterval(t * 3600), windMS: wind, gustMS: gust,
                               windFromDegrees: 200 + t, pressureHPa: pressure, precipitationChance: rain))
        }
        var days: [WeatherReport.Day] = []
        for i in 0..<10 {
            let high: Double = 14 - Double(i % 3)
            let low: Double = 4 + Double(i % 2)
            let wind: Double = 4 + Double(i % 4)
            days.append(.init(date: start.addingTimeInterval(Double(i) * 86_400), highC: high, lowC: low,
                              windMS: wind, windFromDegrees: 225, precipitationChance: i == 1 ? 0.8 : 0.2))
        }
        return WeatherReport(
            now: .init(temperatureC: 12, windMS: 3, gustMS: 6, windFromDegrees: 200,
                       pressureHPa: 1016, pressureTrend: .falling, humidity: 0.72),
            hours: hours, days: days,
            alerts: [.init(summary: "Силен вятър", severity: "Умерено", source: "Синтетичен източник",
                           detailsURL: nil)],
            attribution: nil)
    }
}
#endif
