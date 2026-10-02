import XCTest
@testable import Agrent

/// The phone this app is tested on reports `AppleLocale = en_BG` — English
/// language, Bulgarian region, an entirely ordinary thing for a person to
/// have set. On that device `Date.formatted` produced "11 September 2026"
/// while SwiftUI's `Text(date, format:)` two tabs away produced
/// "21 септември". Same app, same format style, two idioms, two languages.
final class BgDateTests: XCTestCase {

    private var september11: Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "Europe/Sofia"),
            year: 2026, month: 9, day: 11, hour: 12
        ).date!
    }

    /// The assertion that matters: Bulgarian regardless of what the process
    /// locale happens to be. Running under en_US on CI and bg_BG locally
    /// must give the same answer, which is the whole point of declaring it.
    func testMonthsAreBulgarianWhateverTheProcessLocaleIs() {
        XCTAssertTrue(BgDate.full(september11).contains("септември"),
                      BgDate.full(september11))
        XCTAssertTrue(BgDate.dayMonth(september11).contains("септември"),
                      BgDate.dayMonth(september11))
    }

    /// And specifically NOT the English the device would otherwise give.
    func testTheEnglishFormIsNotProduced() {
        for text in [BgDate.full(september11), BgDate.dayMonth(september11)] {
            XCTAssertFalse(text.contains("September"), text)
            XCTAssertFalse(text.contains("Sep"), text)
        }
    }

    /// `full` carries the year, `dayMonth` does not — rows do not need it
    /// and it costs width the chip beside them wants.
    func testOnlyTheFullFormCarriesTheYear() {
        XCTAssertTrue(BgDate.full(september11).contains("2026"))
        XCTAssertFalse(BgDate.dayMonth(september11).contains("2026"))
    }

    /// A clock time, for the pause caption's «в 14:33». Twenty-four hour and
    /// no AM/PM whatever the process locale — the en_US runner and a bg_BG
    /// phone must print the same thing. Built in `Calendar.current` because
    /// `time` formats in the device's zone, so the hour constructed is the
    /// hour shown on any runner.
    func testTheClockTimeIsTwentyFourHourWhateverTheProcessLocaleIs() throws {
        let calendar = Calendar.current
        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 29, hour: 14, minute: 32)))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 29, hour: 9, minute: 5)))
        XCTAssertEqual(BgDate.time(afternoon), "14:32")
        XCTAssertEqual(BgDate.time(morning), "9:05")
        XCTAssertFalse(BgDate.time(afternoon).contains("PM"))
    }

    /// The diagnostics clock: HH:mm:ss, zero-padded and 24-hour everywhere —
    /// a measurement set beside a server log line cannot read "9:05".
    func testTheSecondsClockIsFixedWidth() throws {
        let calendar = Calendar.current
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 2, hour: 9, minute: 5, second: 7)))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 2, hour: 21, minute: 45, second: 59)))
        XCTAssertEqual(BgDate.clockSeconds(morning), "09:05:07")
        XCTAssertEqual(BgDate.clockSeconds(evening), "21:45:59")
    }

    /// A message's time: the clock alone today, the day added otherwise, the
    /// year only when it is not this year. Built in `Calendar.current`, which
    /// is the zone `messageTime` decides "today" in and every form formats in,
    /// so the assertions hold on any runner.
    func testAMessageTimeCarriesTheDayOnlyWhenItIsNotToday() throws {
        let calendar = Calendar.current
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute)))
        }
        let now = try at(2026, 9, 30, 18, 0)

        XCTAssertEqual(BgDate.messageTime(try at(2026, 9, 30, 14, 32), now: now), "14:32")
        XCTAssertEqual(BgDate.messageTime(try at(2026, 9, 30, 0, 5), now: now), "0:05",
                       "just after midnight is still today")
        XCTAssertEqual(BgDate.messageTime(try at(2026, 9, 29, 23, 59), now: now),
                       "29 септември, 23:59", "a minute before midnight is yesterday")
        XCTAssertEqual(BgDate.messageTime(try at(2026, 1, 3, 9, 5), now: now), "3 януари, 9:05")
        // ICU joins the year and «г.» with U+202F, a NARROW no-break space,
        // so the abbreviation never wraps onto a line of its own. Spelled
        // out, because it is invisible in the source and an ordinary space
        // here fails with two strings that print identically.
        XCTAssertEqual(BgDate.messageTime(try at(2025, 12, 31, 14, 32), now: now),
                       "31 декември 2025\u{202F}г., 14:32")
    }

    /// Bulgarian and twenty-four hour whatever the process locale — the en_US
    /// runner and an en_BG phone print the same thing.
    func testAMessageTimeIsNeverEnglish() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 30, hour: 18)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 11, hour: 15, minute: 7)))
        let text = BgDate.messageTime(earlier, now: now)
        XCTAssertEqual(text, "11 септември, 15:07")
        for english in ["September", "Sep", "PM", "AM"] {
            XCTAssertFalse(text.contains(english), text)
        }
    }

    /// The defect this class exists for, stated as a comparison: the raw
    /// idiom and the declared one must not disagree. On a device set to
    /// en_BG the first of these is English.
    func testTheDeclaredFormDiffersFromTheDeviceDefaultUnderEnglishLocales() {
        let deviceStyle = september11.formatted(
            .dateTime.day().month(.wide).year().locale(Locale(identifier: "en_BG")))
        XCTAssertNotEqual(deviceStyle, BgDate.full(september11),
                          "if these are equal the test is no longer testing anything")
        XCTAssertTrue(deviceStyle.contains("September"))
    }
}

/// The task detail route returned a `createdBy.name` of
/// `v1:FTDt/A1v/6KngIxn762VOuI9kQdrKrz69Se6XnFAUBVSb0L/Nm8r` — an encryption
/// envelope, not a name. The screen rendered it under "Създадена от".
final class CipherEnvelopeTests: XCTestCase {
    typealias Assignee = WorkItemSummary.Assignee

    func testTheMeasuredCiphertextIsNotShown() {
        let a = Assignee(
            id: "u1",
            name: "v1:FTDt/A1v/6KngIxn762VOuI9kQdrKrz69Se6XnFAUBVSb0L/Nm8r",
            email: nil
        )
        XCTAssertNil(a.displayName, "54 characters of base64 reached the screen")
    }

    /// It falls through to the email rather than giving up, because an
    /// address is a worse name and still a real one.
    func testACiphertextNameFallsBackToTheEmail() {
        let a = Assignee(id: "u1", name: "v1:AAAA/BBBB", email: "ivan@example.invalid")
        XCTAssertEqual(a.displayName, "ivan@example.invalid")
    }

    /// Matched on the versioned envelope tag, not on "looks like base64" —
    /// a looser rule would eventually eat a real value.
    func testRealNamesAreNotMistakenForCiphertext() {
        for name in [
            "Иван Петров", "Svetoslav Radolovski", "v", "v1", "vera",
            "Vasil", ":", "x:y", "1v:abc", "V1:abc".lowercased() == "v1:abc" ? "Вера" : "Вера",
        ] {
            XCTAssertEqual(
                Assignee(id: "u", name: name, email: nil).displayName, name,
                "\(name) was rejected as ciphertext"
            )
        }
    }

    func testEnvelopeDetection() {
        XCTAssertTrue(Assignee.isCipherEnvelope("v1:abc"))
        XCTAssertTrue(Assignee.isCipherEnvelope("v2:abc"))
        XCTAssertTrue(Assignee.isCipherEnvelope("v10:abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope("v:abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope("va1:abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope(":abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope("Иван Петров"))
    }
    // MARK: - The write side, and the off-by-one-day it fixes

    /// A DAY PICKED IS THE DAY SENT, at every hour of it.
    ///
    /// Two forms formatted a picked day with
    /// `date.formatted(.iso8601.year().month().day()…)`, which defaults to
    /// `timeZone: .gmt`. Bulgaria is UTC+3 in summer and a `DatePicker` in
    /// `.date` mode keeps the time of day it opened with, so a cost dated 25.09
    /// at 00:30 went to the server as 2026-09-24 — into the farm's books, and
    /// into an exchange listing's expiry.
    ///
    /// Written against `Calendar.current` rather than a pinned zone, so the
    /// assertion is the INVARIANT and not this machine's offset: whatever zone
    /// the runner is in, the day that was constructed is the day that comes out.
    /// A test pinning Europe/Sofia would pass on CI while proving nothing there.
    func testTheDayPickedIsTheDaySent() throws {
        let calendar = Calendar.current
        for hour in [0, 1, 2, 3, 12, 22, 23] {
            let picked = try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 9, day: 25, hour: hour, minute: 30)))
            XCTAssertEqual(BgDate.isoDay(picked), "2026-09-25",
                           "a day picked at \(hour):30 local")
        }
    }

    /// And it round-trips through the parser that has always owned this format,
    /// which is the reason the write side belongs on the same type: a reader and
    /// a writer that disagreed about the zone was the same bug from the other
    /// direction.
    func testTheWriteSideRoundTripsThroughTheParser() throws {
        let calendar = Calendar.current
        let picked = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 0, minute: 5)))
        let back = try XCTUnwrap(BgDate.parseISODay(BgDate.isoDay(picked)))
        XCTAssertTrue(calendar.isDate(back, inSameDayAs: picked))
        XCTAssertEqual(BgDate.isoDay(back), BgDate.isoDay(picked))
    }

}
