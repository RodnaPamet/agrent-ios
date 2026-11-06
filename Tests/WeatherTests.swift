import XCTest
@testable import Agrent

/// «Времето» (#551): the words and numbers the sheet shows, and that a test
/// run never asks Apple.
final class WeatherTests: XCTestCase {

    func testTheCompassIsBulgarianInEightPoints() {
        XCTAssertEqual(WeatherWords.compass(0), "С")
        XCTAssertEqual(WeatherWords.compass(44), "СИ")
        XCTAssertEqual(WeatherWords.compass(90), "И")
        XCTAssertEqual(WeatherWords.compass(225), "ЮЗ")
        XCTAssertEqual(WeatherWords.compass(337.6), "С", "past NNW is north again")
        XCTAssertEqual(WeatherWords.compass(-45), "СЗ")
        XCTAssertEqual(WeatherWords.compassSpoken(315), "северозапад")
    }

    func testNumbersAreBulgarianAndPressureIsNotGrouped() {
        XCTAssertEqual(WeatherWords.speed(4.25), "4,2 м/с")
        XCTAssertEqual(WeatherWords.pressure(1013.4), "1013 hPa", "no «1 013»")
        XCTAssertEqual(WeatherWords.temperature(-3.4), "-3°")
        XCTAssertEqual(WeatherWords.percent(0.72), "72 %")
    }

    /// The "cyclone dynamics" a point forecast can show: where the
    /// pressure is heading, and by how much over a day.
    func testTheTrendSaysWhatIsComing() {
        XCTAssertTrue(WeatherWords.trend(.falling)?.contains("циклон") == true)
        XCTAssertTrue(WeatherWords.trend(.rising)?.contains("антициклон") == true)
        XCTAssertNil(WeatherWords.trend(.unknown))

        let start = Date(timeIntervalSince1970: 0)
        let hours = (0..<30).map {
            WeatherReport.Hour(date: start.addingTimeInterval(Double($0) * 3600), windMS: 3, gustMS: nil,
                               windFromDegrees: 200, pressureHPa: 1016 - Double($0) * 0.4,
                               precipitationChance: 0)
        }
        let change = try? XCTUnwrap(WeatherWords.pressureChange(hours))
        XCTAssertEqual(change ?? 0, -9.6, accuracy: 0.001)
        XCTAssertEqual(WeatherWords.changeText(-9.6), "−10 hPa за 24 ч")
        XCTAssertTrue(WeatherWords.isSharpFall(-9.6))
        XCTAssertFalse(WeatherWords.isSharpFall(-2))
        XCTAssertNil(WeatherWords.pressureChange(Array(hours.prefix(10))), "a short forecast says nothing")
    }

    /// Apple's alert text is shown only when it is Bulgarian (owner,
    /// 2026-10-13: no English prose).
    func testAnEnglishAlertGetsABulgarianTitle() {
        XCTAssertEqual(WeatherWords.alertTitle("Силен вятър"), "Силен вятър")
        XCTAssertEqual(WeatherWords.alertTitle("Yellow wind warning"), "Предупреждение за времето")
    }

    /// The seam's fixture under A11yShots, Apple's service otherwise; and
    /// the fixture is a low coming in, so the screenshot shows what the
    /// sheet is for.
    func testTheFixtureIsALowComingIn() async throws {
        let report = try await FixtureWeatherSource().report(latitude: 43.4, longitude: 24.6)
        XCTAssertEqual(report.now.pressureTrend, .falling)
        XCTAssertEqual(report.hours.count, 48)
        XCTAssertEqual(report.days.count, 10)
        XCTAssertTrue(WeatherWords.isSharpFall(try XCTUnwrap(WeatherWords.pressureChange(report.hours))))
        XCTAssertTrue(WeatherSources.current is AppleWeatherSource, "a unit test run is not under the seam")
    }
}
