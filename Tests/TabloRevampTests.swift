import XCTest
@testable import Agrent

/// The revamped Табло (#671, owner 2026-11-17).
final class TabloRevampTests: XCTestCase {
    private let sofia: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return c
    }()

    func testRainfallSplitsMeasuredFromForecastAndTotalsOnlyTheMeasured() throws {
        let json = #"{"daily":{"time":["2026-11-24","2026-11-25","2026-11-26","2026-11-27","2026-11-28"],"precipitation_sum":[2.5,null,1.5,4.0,0.0]}}"#
        let now = try XCTUnwrap(sofia.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 12)))
        let r = try RainfallAPI.rainfall(Data(json.utf8), now: now, calendar: sofia)
        // A missing day is left out, never counted as dry.
        XCTAssertEqual(r.days.count, 4)
        XCTAssertEqual(r.days.filter(\.isForecast).count, 2)
        // Today counts as measured.
        XCTAssertEqual(r.measuredTotal, 4.0, accuracy: 1e-9)
    }

    func testTheRainfallRequestAsksForThirtyDaysBackAndSevenAhead() throws {
        let url = RainfallAPI.url(latitude: 42.7, longitude: 23.3)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(URLQueryItem(name: "past_days", value: "30")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "forecast_days", value: "8")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "daily", value: "precipitation_sum")))
    }

    func testThePhonesPositionIsRoundedToTheGrid() {
        XCTAssertEqual(WeatherPlace.rounded(43.2187), 43.2, accuracy: 1e-9)
        XCTAssertEqual(WeatherPlace.rounded(24.2849), 24.3, accuracy: 1e-9)
        XCTAssertEqual(WeatherPlace.rounded(24.2749), 24.25, accuracy: 1e-9)
    }

    /// What reaches Apple Weather and Open-Meteo has at most two decimals —
    /// under Apple's "three or more decimal places" line for Precise Location.
    func testTheSentCoordinateNeverHasThreeDecimals() {
        for raw in stride(from: 41.0, through: 44.5, by: 0.0137) {
            let text = String(WeatherPlace.rounded(raw))
            let decimals = text.split(separator: ".").dropFirst().first?.count ?? 0
            XCTAssertLessThanOrEqual(decimals, 2, "\(raw) → \(text)")
        }
        let url = RainfallAPI.url(latitude: WeatherPlace.rounded(43.1499), longitude: WeatherPlace.rounded(24.2851))
        XCTAssertTrue(url.absoluteString.contains("latitude=43.15&longitude=24.3"), url.absoluteString)
    }

    func testWithoutAPhoneFixTheWeatherIsForTheCentreOfTheBlocks() throws {
        let json = #"""
        [{"id":"a","name":"А","status":"ACTIVE","boundsJson":[24.0,43.0,24.2,43.2]},
         {"id":"b","name":"Б","status":"ACTIVE","boundsJson":[24.4,43.4,24.6,43.6]},
         {"id":"c","name":"В","status":"ACTIVE"}]
        """#
        let blocks = try JSONDecoder().decode([Location].self, from: Data(json.utf8))
        let point = try XCTUnwrap(WeatherPlace.farmCentre(blocks))
        XCTAssertEqual(point.latitude, 43.3, accuracy: 1e-9)
        XCTAssertEqual(point.longitude, 24.3, accuracy: 1e-9)
        XCTAssertFalse(point.isPhone)
        XCTAssertNil(WeatherPlace.farmCentre([]))
    }

    func testTheWords() {
        XCTAssertEqual(DashboardWords.degrees(11.6), "12°")
        XCTAssertEqual(DashboardWords.wind(3.6), "4 м/с")
        XCTAssertEqual(DashboardWords.millimetres(41.96), "42 мм")
        XCTAssertEqual(DashboardBlock.weather.label, "Времето")
        XCTAssertEqual(DashboardBlock.rainfall.label, "Валежи")
    }
}
