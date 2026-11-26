import Foundation

/// Табло's rainfall chart (#671, owner 2026-11-17): the last 30 days as
/// measured, then 7 days ahead as forecast, in millimetres per day — one unit
/// for both halves, so the bars compare. Open-Meteo, free tier, the source the
/// risk screen already uses for "rain since".
struct Rainfall: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        let date: Date
        let millimetres: Double
        /// Ahead of today: drawn lighter, and left out of the total.
        let isForecast: Bool
        var id: Date { date }
    }

    let days: [Day]

    /// The one number: the 30 measured days' total.
    var measuredTotal: Double { days.filter { !$0.isForecast }.reduce(0) { $0 + $1.millimetres } }
}

protocol RainfallSource: Sendable {
    func rainfall(latitude: Double, longitude: Double) async throws -> Rainfall
}

enum RainfallSources {
    static var current: any RainfallSource {
        #if DEBUG
        if UITestSeam.isActive { return FixtureRainfallSource() }
        #endif
        return OpenMeteoRainfallSource()
    }
}

struct OpenMeteoRainfallSource: RainfallSource {
    func rainfall(latitude: Double, longitude: Double) async throws -> Rainfall {
        var request = URLRequest(url: RainfallAPI.url(latitude: latitude, longitude: longitude),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        ClientHeader.stamp(&request)
        request.httpShouldHandleCookies = false
        let (data, response) = try await NoURLCache.thirdPartySession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try RainfallAPI.rainfall(data)
    }
}

enum RainfallAPI {
    static let measuredDays = 30
    static let forecastDays = 7

    /// `forecast_days` counts today, so one more than the days ahead.
    static func url(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "daily", value: "precipitation_sum"),
            URLQueryItem(name: "past_days", value: String(measuredDays)),
            URLQueryItem(name: "forecast_days", value: String(forecastDays + 1)),
            // Bulgaria's days, so a day's total is the farmer's day.
            URLQueryItem(name: "timezone", value: "Europe/Sofia"),
        ]
        return components.url!
    }

    private struct Answer: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let precipitation_sum: [Double?]
        }
        let daily: Daily
    }

    /// Today counts as measured; a missing value is a day left out, never 0 —
    /// a gap in the record is not a dry day.
    static func rainfall(_ data: Data, now: Date = Date(), calendar: Calendar = .current) throws -> Rainfall {
        let daily = try JSONDecoder().decode(Answer.self, from: data).daily
        let today = calendar.startOfDay(for: now)
        let days: [Rainfall.Day] = daily.time.enumerated().compactMap { index, text in
            guard let date = day(text, in: calendar),
                  daily.precipitation_sum.indices.contains(index),
                  let mm = daily.precipitation_sum[index] else { return nil }
            return .init(date: date, millimetres: max(mm, 0), isForecast: date > today)
        }
        return Rainfall(days: days)
    }

    /// `2026-11-26` as that day's start IN `calendar` — the calendar `today`
    /// comes from. Read in the device's zone instead, a day label lands two
    /// or three hours off `today` whenever the two zones differ, and today's
    /// rain is counted as forecast (measured: CI runs in UTC).
    private static func day(_ text: String, in calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

#if DEBUG
/// A wet spell, a dry fortnight and showers ahead — synthetic, for A11yShots.
struct FixtureRainfallSource: RainfallSource {
    func rainfall(latitude: Double, longitude: Double) async throws -> Rainfall {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let pattern: [Double] = [0, 2.4, 8.1, 0.6, 0, 0, 0, 12.5, 3.2, 0, 0, 0, 0, 0, 0,
                                 0, 0, 1.1, 0, 0, 4.4, 9.8, 0.3, 0, 0, 0, 0, 0.8, 0, 0, 0]
        var days: [Rainfall.Day] = []
        for (offset, mm) in pattern.enumerated() {
            guard let date = calendar.date(byAdding: .day, value: offset - 30, to: today) else { continue }
            days.append(.init(date: date, millimetres: mm, isForecast: false))
        }
        for (offset, mm) in [0.0, 3.5, 6.2, 0, 0, 1.4, 0].enumerated() {
            guard let date = calendar.date(byAdding: .day, value: offset + 1, to: today) else { continue }
            days.append(.init(date: date, millimetres: mm, isForecast: true))
        }
        return Rainfall(days: days)
    }
}
#endif
