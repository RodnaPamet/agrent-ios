import Foundation
import Observation

/// How much it has rained on a parcel since its satellite picture (owner,
/// 2026-11-08). A satellite reads through no cloud, so a wet week is a week
/// without a picture, and the last reading is from before the rain: «Влага:
/// Стрес» under a week of downpour. The rain since the picture puts an old
/// reading in its place.
///
/// Open-Meteo's free tier, as the block map's wind (`OpenMeteoWindSource`,
/// owner's choice 2026-11-06): one place, hourly rain over the past days.
/// A protocol so A11yShots reads a fixture and no test calls Open-Meteo.
protocol RainSource: Sendable {
    /// Millimetres from the start of the day after `day`, in the phone's
    /// zone, up to now. The pass is mid-morning, and rain later that day
    /// may fall before or after it; the next day's is certainly after.
    func millimetres(latitude: Double, longitude: Double, after day: Date) async throws -> Double
}

enum RainSources {
    static var current: any RainSource {
        #if DEBUG
        if UITestSeam.isActive { return FixtureRainSource() }
        #endif
        return OpenMeteoRainSource()
    }
}

struct OpenMeteoRainSource: RainSource {
    func millimetres(latitude: Double, longitude: Double, after day: Date) async throws -> Double {
        let since = RainSinceAPI.start(after: day)
        let url = RainSinceAPI.url(latitude: latitude, longitude: longitude, pastDays: RainSinceAPI.pastDays(since: since))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        ClientHeader.stamp(&request)
        request.httpShouldHandleCookies = false
        let (data, response) = try await NoURLCache.thirdPartySession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try RainSinceAPI.sum(data, from: since)
    }
}

enum RainSinceAPI {
    /// Open-Meteo keeps 92 past days on the forecast endpoint; a picture
    /// older than that is not one the screen puts rain beside.
    static let maxPastDays = 92

    static func url(latitude: Double, longitude: Double, pastDays: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "precipitation"),
            URLQueryItem(name: "past_days", value: String(pastDays)),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return components.url!
    }

    /// The start of the day after `day`, in the phone's zone.
    static func start(after day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
    }

    /// Whole days back to `since`, plus one so its first hours are in.
    static func pastDays(since: Date, now: Date = Date()) -> Int {
        let days = Int((now.timeIntervalSince(since) / 86_400).rounded(.up)) + 1
        return min(max(days, 1), maxPastDays)
    }

    private struct Answer: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let precipitation: [Double?]
        }
        let hourly: Hourly
    }

    /// The hours from `since` up to `now`: the request carries today's
    /// forecast hours too, which have not fallen yet.
    static func sum(_ data: Data, from since: Date, now: Date = Date()) throws -> Double {
        let hourly = try JSONDecoder().decode(Answer.self, from: data).hourly
        var total = 0.0
        for (index, text) in hourly.time.enumerated() {
            guard let hour = OpenMeteoAPI.parseHour(text), hour >= since, hour < now,
                  hourly.precipitation.indices.contains(index), let mm = hourly.precipitation[index] else { continue }
            total += mm
        }
        return total
    }
}

/// The sentence, pure so tests pin it. Nil for a picture from today, or
/// when nothing fell: the line is there to explain an old dry reading,
/// and «не е валяло» explains nothing.
enum RainSinceWords {
    static func text(_ millimetres: Double, after day: Date) -> String? {
        let rounded = millimetres.rounded()
        guard millimetres >= 1 else { return nil }
        return "След \(BgDate.dayMonth(day)) е валяло \(WeatherWords.number(rounded, places: 0))\u{00A0}мм, а снимката е отпреди това."
    }
}

/// One parcel's rain since its picture, loaded once per picture date.
@MainActor
@Observable
final class RainSinceStore {
    private(set) var millimetres: Double?
    private var asked: (day: Date, latitude: Double, longitude: Double)?
    private let source: any RainSource

    init(source: any RainSource = RainSources.current) { self.source = source }

    func load(latitude: Double, longitude: Double, after day: Date) async {
        if let asked, asked.day == day, asked.latitude == latitude, asked.longitude == longitude { return }
        asked = (day, latitude, longitude)
        // Quietly nothing on failure: the line is context, not the reading,
        // and a third party's outage is not worth an error under «Риск».
        millimetres = try? await source.millimetres(latitude: latitude, longitude: longitude, after: day)
    }
}

#if DEBUG
/// A wet week, for A11yShots. Invented.
struct FixtureRainSource: RainSource {
    func millimetres(latitude: Double, longitude: Double, after day: Date) async throws -> Double { 42.4 }
}
#endif
