import XCTest
@testable import Agrent

/// Rain and temperature per day under a parcel's «Риск» chart (owner,
/// 2026-11-16). Synthetic numbers; nothing calls Open-Meteo.
final class DailyWeatherTests: XCTestCase {

    private func day(_ text: String, rain: Double?, high: Double? = nil, low: Double? = nil) throws -> DailyWeather {
        DailyWeather(date: try XCTUnwrap(BgDate.parseISODay(text)), rain: rain, high: high, low: low)
    }

    func testTheRequestAsksForDailyTotalsInBulgariasDays() throws {
        let url = DailyWeatherAPI.url(latitude: 42.5, longitude: 25.1, pastDays: 300)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("daily"), "precipitation_sum,temperature_2m_max,temperature_2m_min")
        XCTAssertEqual(value("past_days"), "92", "clamped to what the free tier keeps")
        XCTAssertEqual(value("timezone"), "Europe/Sofia")
    }

    /// Today's total is part forecast, so it is left out.
    func testTodayIsLeftOut() throws {
        let json = """
        {"daily":{"time":["2026-11-14","2026-11-15","2026-11-16"],
          "precipitation_sum":[1.5,null,9],"temperature_2m_max":[9,8,7],"temperature_2m_min":[-1,2,3]}}
        """
        let now = try XCTUnwrap(BgDate.parseISODay("2026-11-16")).addingTimeInterval(3600 * 10)
        let days = try DailyWeatherAPI.days(Data(json.utf8), now: now)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].rain, 1.5)
        XCTAssertNil(days[1].rain)
        XCTAssertEqual(days[0].low, -1)
    }

    func testRainInLitresPerSquareMetre() throws {
        let days = [try day("2026-11-08", rain: 2.4), try day("2026-11-09", rain: 12.2), try day("2026-11-10", rain: 0)]
        XCTAssertEqual(DailyWeatherWords.rain(days, period: 14),
                       "За 14 дни са паднали 15\u{00A0}л/м². Най-много на 9 ноември: 12\u{00A0}л/м².")
        XCTAssertEqual(DailyWeatherWords.rain([try day("2026-11-08", rain: 0.1)], period: 30), "За 30 дни не е валяло.")
        XCTAssertNil(DailyWeatherWords.rain([try day("2026-11-08", rain: nil)], period: 30))
    }

    func testTemperatureNamesTheExtremesAndTheFrosts() throws {
        let days = [try day("2026-11-08", rain: nil, high: 18.2, low: 3), try day("2026-11-10", rain: nil, high: 6, low: -2.6),
                    try day("2026-11-11", rain: nil, high: 5, low: -0.4)]
        XCTAssertEqual(DailyWeatherWords.temperature(days),
                       "Най-ниско −3° на 10 ноември, най-високо 18° на 8 ноември. Дни с минусова температура: 2.")
    }

    /// The axis is the period chosen, whatever the passes cover.
    func testThePeriodEndsToday() throws {
        let now = try XCTUnwrap(BgDate.parseISODay("2026-11-16")).addingTimeInterval(3600)
        let period = RiskTrendPoints.period(days: 14, now: now)
        XCTAssertEqual(period.lowerBound, try XCTUnwrap(BgDate.parseISODay("2026-11-02")))
        XCTAssertEqual(period.upperBound, try XCTUnwrap(BgDate.parseISODay("2026-11-16")))
    }

    func testTheMenuKeepsOneIndex() {
        XCTAssertEqual(RiskTrendMetric.ndvi.index, .ndvi)
        XCTAssertNil(RiskTrendMetric.rain.index)
        XCTAssertTrue(RiskTrendMetric.temperature.isWeather)
        XCTAssertFalse(RiskTrendMetric.indices.isWeather)
    }
}
