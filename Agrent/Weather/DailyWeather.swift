import Foundation
import Observation

/// A parcel's rain and temperature per day over the period its «Риск»
/// chart shows (owner, 2026-11-16: "a dropdown to choose between different
/// metrics. One needed is rain"). Beside the satellite lines it answers the
/// question they raise: was it dry, did it freeze.
///
/// Open-Meteo's free tier, as `RainSinceStore` (owner's choice
/// 2026-11-06): one place, daily totals, up to 92 past days. A protocol so
/// A11yShots reads a fixture and no test calls Open-Meteo.
protocol DailyWeatherSource: Sendable {
    func days(latitude: Double, longitude: Double, pastDays: Int) async throws -> [DailyWeather]
}

/// One finished day: today is left out, as its total is part forecast.
struct DailyWeather: Equatable, Sendable, Identifiable {
    let date: Date
    /// Millimetres, which is litres per square metre.
    let rain: Double?
    let high: Double?
    let low: Double?
    var id: Date { date }
}

enum DailyWeatherSources {
    static var current: any DailyWeatherSource {
        #if DEBUG
        if UITestSeam.isActive { return FixtureDailyWeatherSource() }
        #endif
        return OpenMeteoDailyWeatherSource()
    }
}

struct OpenMeteoDailyWeatherSource: DailyWeatherSource {
    func days(latitude: Double, longitude: Double, pastDays: Int) async throws -> [DailyWeather] {
        var request = URLRequest(url: DailyWeatherAPI.url(latitude: latitude, longitude: longitude, pastDays: pastDays),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        ClientHeader.stamp(&request)
        request.httpShouldHandleCookies = false
        let (data, response) = try await NoURLCache.thirdPartySession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try DailyWeatherAPI.days(data)
    }
}

enum DailyWeatherAPI {
    static func url(latitude: Double, longitude: Double, pastDays: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "daily", value: "precipitation_sum,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "past_days", value: String(min(max(pastDays, 1), RainSinceAPI.maxPastDays))),
            URLQueryItem(name: "forecast_days", value: "1"),
            // Bulgaria's days, so a day's total is the farmer's day.
            URLQueryItem(name: "timezone", value: "Europe/Sofia"),
        ]
        return components.url!
    }

    private struct Answer: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let precipitation_sum: [Double?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
        }
        let daily: Daily
    }

    /// The finished days, oldest first.
    static func days(_ data: Data, now: Date = Date(), calendar: Calendar = .current) throws -> [DailyWeather] {
        let daily = try JSONDecoder().decode(Answer.self, from: data).daily
        let today = calendar.startOfDay(for: now)
        func at(_ values: [Double?], _ index: Int) -> Double? { values.indices.contains(index) ? values[index] : nil }
        return daily.time.enumerated().compactMap { index, text in
            guard let date = BgDate.parseISODay(text), date < today else { return nil }
            return DailyWeather(date: date, rain: at(daily.precipitation_sum, index),
                                high: at(daily.temperature_2m_max, index), low: at(daily.temperature_2m_min, index))
        }
    }
}

/// The period's rain and frost in a sentence each. Pure, so tests pin it.
enum DailyWeatherWords {
    /// «За 14 дни са паднали 23 л/м². Най-много на 9 ноември: 12 л/м².»
    static func rain(_ days: [DailyWeather], period: Int) -> String? {
        let wet = days.compactMap { day in day.rain.map { (day.date, $0) } }
        guard !wet.isEmpty else { return nil }
        let total = wet.reduce(0) { $0 + $1.1 }
        guard total >= 0.5 else { return "За \(period) дни не е валяло." }
        var text = "За \(period) дни са паднали \(litres(total))."
        if let most = wet.max(by: { $0.1 < $1.1 }), most.1 >= 0.5, wet.filter({ $0.1 >= 0.5 }).count > 1 {
            text += " Най-много на \(BgDate.dayMonth(most.0)): \(litres(most.1))."
        }
        return text
    }

    /// «Най-ниско −3° на 10 ноември, най-високо 18° на 2 ноември. Дни под 0°: 3.»
    static func temperature(_ days: [DailyWeather]) -> String? {
        let lows = days.compactMap { day in day.low.map { (day.date, $0) } }
        let highs = days.compactMap { day in day.high.map { (day.date, $0) } }
        guard let low = lows.min(by: { $0.1 < $1.1 }), let high = highs.max(by: { $0.1 < $1.1 }) else { return nil }
        var text = "Най-ниско \(degrees(low.1)) на \(BgDate.dayMonth(low.0)), най-високо \(degrees(high.1)) на \(BgDate.dayMonth(high.0))."
        let frosts = lows.filter { $0.1 < 0 }.count
        if frosts > 0 { text += " Дни с минусова температура: \(frosts)." }
        return text
    }

    /// «12 л/м²»: a millimetre of rain is a litre on each square metre.
    static func litres(_ value: Double) -> String {
        "\(WeatherWords.number(value, places: value < 10 ? 1 : 0))\u{00A0}л/м²"
    }

    /// «−3°» with a real minus.
    static func degrees(_ value: Double) -> String {
        let rounded = value.rounded()
        return (rounded < 0 ? "−" : "") + WeatherWords.number(abs(rounded), places: 0) + "°"
    }
}

/// One parcel's days, loaded once per place and period.
@MainActor
@Observable
final class DailyWeatherStore {
    private(set) var state: LoadState<[DailyWeather]> = .loading
    private var asked: (days: Int, latitude: Double, longitude: Double)?
    private let source: any DailyWeatherSource

    init(source: any DailyWeatherSource = DailyWeatherSources.current) { self.source = source }

    func load(days: Int, latitude: Double, longitude: Double) async {
        if let asked, asked.days == days, asked.latitude == latitude, asked.longitude == longitude,
           !state.isFailed { return }
        asked = (days, latitude, longitude)
        state = .loading
        do {
            let answer = try await source.days(latitude: latitude, longitude: longitude, pastDays: days)
            guard asked?.days == days else { return }
            state = .loaded(answer, .fresh)
        } catch {
            guard asked?.days == days, !(error is CancellationError) else { return }
            state = .failed("Няма данни за времето в момента. Опитайте отново по-късно.")
        }
    }
}

#if DEBUG
/// A wet spell and two frosty nights, for A11yShots. Invented.
struct FixtureDailyWeatherSource: DailyWeatherSource {
    func days(latitude: Double, longitude: Double, pastDays: Int) async throws -> [DailyWeather] {
        let today = Calendar.current.startOfDay(for: Date())
        return (1...pastDays).reversed().compactMap { back in
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: today) else { return nil }
            let rain: Double = [0, 0, 4.2, 12.6, 1.1, 0, 0][back % 7]
            return DailyWeather(date: date, rain: rain, high: 8 + Double(back % 5), low: back % 9 == 0 ? -2 : 2)
        }
    }
}
#endif
