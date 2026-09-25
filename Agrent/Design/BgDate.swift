import Foundation

/// Dates in Bulgarian, explicitly, whatever the phone thinks its locale is.
///
/// ── Two idioms that disagree, in one app ──
///
/// Measured on the device, 2026-09-22. `AppleLocale` on this phone is
/// **en_BG** — English language, Bulgarian region, which is an entirely
/// ordinary thing for a person to have set. On that device:
///
///     Text(date, format: .dateTime.day().month(.wide))  →  "21 септември"
///     date.formatted(.dateTime.day().month(.wide))      →  "21 September"
///
/// Same date, same format style, same screen. SwiftUI's `Text` resolves
/// through the environment's locale; `Date.formatted` goes straight to
/// `Locale.current`. The app had both, so `TaskDetailView` printed
/// "11 September 2026" under a Bulgarian label while the journal two tabs
/// away printed "21 септември".
///
/// ── The one that had already shipped ──
///
/// Worse than the visible mismatch: `JournalRow`'s ACCESSIBILITY label was
/// built with `.formatted()`. The screen read "21 септември" and VoiceOver
/// said "21 September" — a discrepancy invisible to everyone who can see the
/// screen, which is everyone who reviewed it.
///
/// ── Why an explicit locale and not just the SwiftUI idiom ──
///
/// `Text(date, format:)` happens to be right here, and "happens to be" is
/// the problem: it depends on how SwiftUI resolves an environment locale for
/// an app with no localisation bundle, which is not a contract anybody
/// stated. This app is Bulgarian-only — every literal in it is hard-coded
/// Bulgarian, by the same decision recorded in `UserMessage` — so its dates
/// are Bulgarian by declaration rather than by inheritance. One idiom, used
/// for display and for VoiceOver both, so the two cannot drift again.
enum BgDate {
    /// Not `Locale.current`. That is the value that was wrong.
    static let locale = Locale(identifier: "bg_BG")

    /// 21 септември 2026 г.
    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(locale))
    }

    /// 21 септември — for rows, where the year is usually noise.
    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).locale(locale))
    }

    /// `"2026-09-19"` → that calendar day.
    ///
    /// The agro endpoints answer with a date-only string, which is a DAY and
    /// not an instant. Parsing it as UTC midnight and rendering it in the
    /// device's zone is the shape that silently loses a day west of
    /// Greenwich, so both ends use `.current` and the value round-trips to
    /// the same digits it arrived as.
    ///
    /// `en_US_POSIX` for the parse, `bg_BG` for the display: a fixed format
    /// must be read against a fixed locale, or a device set to a calendar
    /// that is not Gregorian reads `2026` as a year it is not.
    static func parseISODay(_ string: String) -> Date? {
        isoDay.date(from: string)
    }

    /// A calendar day as `yyyy-MM-dd`, IN THE DEVICE'S ZONE — the write side of
    /// `parseISODay`, and the fix for a real off-by-one-day.
    ///
    /// ── What it replaces, and what that cost ──
    ///
    /// Two forms sent a picked day with
    /// `date.formatted(.iso8601.year().month().day()…)`. `ISO8601FormatStyle`
    /// defaults to `timeZone: .gmt`, and Bulgaria is UTC+3 in summer. Measured
    /// with a probe:
    ///
    ///     picked in the DatePicker   25.09.2026 г., 0:30
    ///     sent on the wire           2026-09-24
    ///
    /// A `DatePicker` in `.date` mode keeps the time of day it started with, so
    /// any cost or listing filled in between midnight and 03:00 local was
    /// booked to the PREVIOUS day. On a farm that is the end of a long day, not
    /// an edge case, and on `NewCostView` it is the farm's books.
    ///
    /// ── Why here and not a local formatter ──
    ///
    /// `parseISODay` already pins this exact contract for READING, and its
    /// header explains why both ends must use `.current`: parsing a day as UTC
    /// midnight and rendering it in the device's zone silently loses a day west
    /// of Greenwich. A write side that disagreed with it was the same bug from
    /// the other direction. One type owns the day format in both directions
    /// now, so they cannot drift again.
    static func isoDay(_ date: Date) -> String {
        isoDayWriter.string(from: date)
    }

    /// Separate from `isoDay` the parser only because a `DateFormatter` is
    /// cheap to hold and sharing one mutable instance across read and write
    /// invites somebody to set `dateFormat` on it.
    private static let isoDayWriter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// An agro timestamp whose RESPONSE schema does not pin a format.
    ///
    /// ── Why this is not `parseISODay`, and not a `Date` property either ──
    ///
    /// The parcel-history contract is asymmetric, and deliberately read from
    /// the generated spec rather than from anybody's memory of it
    /// (`src/generated/openapi.json`, fetched 2026-09-25):
    ///
    ///     CreateParcelCropSeason.sownAt        string, format: date-time
    ///     ParcelCropSeason.sownAt              string, NO format
    ///     CreateParcelWeedObservation.observedAt   string, format: date-time
    ///     ParcelWeedObservation.observedAt     string, NO format
    ///
    /// The writes are pinned to an instant. The reads are pinned to nothing
    /// at all — so a full instant is what the server sends today, and a bare
    /// `2026-09-19` is what its own published contract still permits.
    ///
    /// Declaring these as `Date` properties would decode them through
    /// `APIClient`'s strategy, which accepts ISO 8601 instants and THROWS on
    /// anything else. One season with a date-only `sownAt` would then fail
    /// the whole archive payload — every season, every operation, every weed
    /// observation, on a screen where the dates are the least of what the
    /// farmer came for.
    ///
    /// So both shapes are accepted here, and the models keep the string
    /// beside the parsed value for the case where neither matches.
    static func parseInstantOrDay(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return instantWithFraction.date(from: string)
            ?? instant.date(from: string)
            ?? parseISODay(string)
    }

    /// Two formatters, because `ISO8601DateFormatter` does not make
    /// fractional seconds optional — `.withFractionalSeconds` REQUIRES them
    /// and its absence REFUSES them. The same pair exists in `APIClient`'s
    /// decoder for the same reason; this is that lesson, not a new one.
    private static let instantWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let instant: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
