import XCTest
@testable import Agrent

/// `BgDate.parseInstant` replaced two `ISO8601DateFormatter`s (P4.6, #195),
/// and every `Date` the API sends goes through it. Pinned to the old
/// formatters' answers on the server's own spelling and the edge cases
/// around it.
final class InstantParsingTests: XCTestCase {

    /// What the app parsed with before #195, kept here as the reference. A
    /// local formatter in a test is no concurrency hazard; the app's shared
    /// ones were.
    private func formatter(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    func testTheServersSpellingsParseAsBefore() throws {
        let cases = [
            "2026-09-18T07:12:00.000Z",        // `toISOString()`: what the server sends
            "2026-09-18T07:12:00Z",            // without the fraction
            "2026-09-18T10:12:00.000+03:00",   // an offset in place of the Z
            "2026-09-18T10:12:00+03:00",
            "2026-09-18T10:12:00.000+0300",
            "2026-09-18T07:12:00.5Z",          // other fraction lengths
            "2026-09-18T07:12:00.123456Z",
            "2026-09-18T07:12:00.000z",
        ]
        for text in cases {
            let old = try XCTUnwrap(formatter(text), "the reference refused \(text)")
            let new = try XCTUnwrap(BgDate.parseInstant(text), "\(text) no longer parses")
            XCTAssertEqual(new.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.001, text)
        }
        // The value itself, not only agreement: 07:12 UTC on 18 September 2026.
        XCTAssertEqual(BgDate.parseInstant("2026-09-18T07:12:00.000Z")?.timeIntervalSince1970,
                       1_789_715_520)
    }

    func testWhatWasRefusedIsStillRefused() {
        for text in ["2026-09-18", "2026-09-18T07:12:00", "not a date", "2026-09-18 07:12:00Z", ""] {
            XCTAssertNil(formatter(text), "the reference accepted \(text)")
            XCTAssertNil(BgDate.parseInstant(text), text)
        }
    }

    /// The one difference found, and it is the stricter side: the old
    /// formatter skipped a leading space. The server's `toISOString()`
    /// never pads, so a padded string is not one of its instants.
    func testAPaddedInstantIsNotTheServers() {
        XCTAssertNotNil(formatter(" 2026-09-18T07:12:00Z"), "positive control")
        XCTAssertNil(BgDate.parseInstant(" 2026-09-18T07:12:00Z"))
    }

    /// The day-only fallback beside it is untouched.
    func testParseInstantOrDayStillTakesBoth() {
        XCTAssertNotNil(BgDate.parseInstantOrDay("2026-09-18"))
        XCTAssertNotNil(BgDate.parseInstantOrDay("2026-09-18T07:12:00.000Z"))
    }
}
