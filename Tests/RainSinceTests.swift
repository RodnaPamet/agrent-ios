import XCTest
@testable import Agrent

/// The rain since a parcel's satellite picture (owner, 2026-11-08), so a
/// reading from before a wet week is read as old, not as dry. Nothing here
/// calls Open-Meteo.
final class RainSinceTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func instant(_ text: String) -> Date { BgDate.parseInstant(text)! }

    func testTheRequestAsksOnePlacesHourlyRain() {
        let url = RainSinceAPI.url(latitude: 43.1, longitude: 24.7, pastDays: 12).absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.open-meteo.com/v1/forecast?"), url)
        for part in ["latitude=43.1", "longitude=24.7", "hourly=precipitation", "past_days=12", "timezone=GMT"] {
            XCTAssertTrue(url.contains(part), part)
        }
        XCTAssertFalse(url.contains("apikey"), "the free tier, no key in this public repo")
    }

    /// Counted from the day AFTER the picture: rain later that day may have
    /// fallen before the pass.
    func testCountingStartsTheDayAfter() {
        let start = RainSinceAPI.start(after: instant("2026-10-28T09:30:00Z"), calendar: utc)
        XCTAssertEqual(start, instant("2026-10-29T00:00:00Z"))
    }

    func testPastDaysCoverTheGapAndStayWithinTheLimit() {
        let now = instant("2026-11-08T12:00:00Z")
        XCTAssertEqual(RainSinceAPI.pastDays(since: instant("2026-10-29T00:00:00Z"), now: now), 12)
        XCTAssertEqual(RainSinceAPI.pastDays(since: instant("2026-01-01T00:00:00Z"), now: now), 92)
        XCTAssertEqual(RainSinceAPI.pastDays(since: now, now: now), 1)
    }

    /// Only hours from the start up to now: not before the picture, and not
    /// today's forecast hours, which have not fallen.
    func testOnlyFallenHoursAfterThePictureAreSummed() throws {
        let json = """
        {"hourly":{"time":["2026-10-28T23:00","2026-10-29T00:00","2026-10-29T01:00","2026-11-08T11:00","2026-11-08T13:00"],
                   "precipitation":[5.0, 1.5, null, 2.0, 9.0]}}
        """
        let mm = try RainSinceAPI.sum(Data(json.utf8), from: instant("2026-10-29T00:00:00Z"),
                                      now: instant("2026-11-08T12:00:00Z"))
        XCTAssertEqual(mm, 3.5, accuracy: 0.001)
    }

    func testTheSentenceSaysThePictureIsOlderThanTheRain() {
        let day = instant("2026-10-28T09:30:00Z")
        let words = RainSinceWords.text(42.4, after: day)
        XCTAssertNotNil(words)
        XCTAssertTrue(words!.hasSuffix("е валяло 42\u{00A0}мм, а снимката е отпреди това."), words!)
        XCTAssertTrue(words!.hasPrefix("След "), words!)
    }

    /// Under a millimetre explains nothing, so nothing is said.
    func testATraceSaysNothing() {
        XCTAssertNil(RainSinceWords.text(0.6, after: Date()))
        XCTAssertNil(RainSinceWords.text(0, after: Date()))
    }

    @MainActor
    func testTheStoreAsksOncePerPicture() async {
        actor Counting: RainSource {
            var calls = 0
            func millimetres(latitude: Double, longitude: Double, after day: Date) async throws -> Double {
                calls += 1
                return 12
            }
        }
        let source = Counting()
        let store = RainSinceStore(source: source)
        let day = instant("2026-10-28T09:30:00Z")
        await store.load(latitude: 43, longitude: 24, after: day)
        await store.load(latitude: 43, longitude: 24, after: day)
        XCTAssertEqual(store.millimetres, 12)
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
    }

    func testTheMoistureNoteSaysPlantsNotSoil() {
        XCTAssertEqual(RiskExplanation.moistureNote, "Влагата (NDMI) е водата в растенията, не в почвата.")
    }
}
