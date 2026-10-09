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

    /// 21 септември this year, 21 септември 2025 г. any other — for a row's
    /// date that can be old. A task opened last autumn and still on the list
    /// would otherwise read as this year's (#236). The year rule is
    /// `messageTime`'s, and `now` and `calendar` are parameters for the same
    /// reason: a test holds them, the app takes the defaults.
    static func rowDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? dayMonth(date) : full(date)
    }

    /// 14:32 — a clock time, for a promise about later today.
    ///
    /// Twenty-four hour because the LOCALE is: measured, bg_BG gives "14:32"
    /// and "9:05" where en_US gives "2:32 PM" for the same instants. Whether
    /// a phone switched to 12-hour time overrides an explicitly named locale
    /// has NOT been checked on a device. Here rather than at the call site,
    /// because the CI step that keeps dates in this file fails any
    /// `.formatted(.dateTime…)` written anywhere else.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// 14:32:05 — a clock time to the SECOND, for Админ → «Диагностика».
    ///
    /// The one place in the app where seconds are the point: the owner times
    /// a flag flip on the server against the moment the phone adopted it, and
    /// a foreground refresh lands within a second or two of the app opening —
    /// at minute resolution every measurement reads "same minute".
    ///
    /// A FIXED `HH:mm:ss`, not `.dateTime.hour().minute().second()` like
    /// `time` above: a measurement is set beside a server log line, so it must
    /// be zero-padded and 24-hour on every phone — `time` gives "9:05", and
    /// whether a 12-hour device setting overrides the locale is unchecked.
    /// `en_US_POSIX` because a fixed format is held against a fixed locale
    /// (see `parseISODay`); the device's zone because the owner reads it
    /// against his own clock.
    static func clockSeconds(_ date: Date) -> String {
        clockSecondsWriter.string(from: date)
    }

    private static let clockSecondsWriter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// A message's time, as a conversation shows it:
    ///
    ///     today                 14:32
    ///     earlier this year     21 септември, 14:32
    ///     an earlier year       21 септември 2025 г., 14:32
    ///
    /// The clock alone for today, because a conversation read today is mostly
    /// today's and the date is noise there. The day is added the moment it is
    /// not today — a "14:32" that was yesterday's reads as an hour ago. The
    /// year only when it differs, as `dayMonth` leaves it off for rows.
    ///
    /// "Today" is the DEVICE's today, in its zone — the same zone every form
    /// here formats in, so the day the test is made against is the day shown.
    /// `now` and `calendar` are parameters so a test can hold them; the app
    /// takes the defaults. The screen and its VoiceOver label must both call
    /// this, so the two cannot say different things (see the header).
    static func messageTime(_ date: Date, now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        return "\(sameYear ? dayMonth(date) : full(date)), \(time(date))"
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

    /// An instant as the server reads one: `2026-10-09T20:59:59.999Z`, in UTC,
    /// with milliseconds. It writes the journal filter's `occurredFrom` and
    /// `occurredTo`, which the server hands straight to `new Date(…)`.
    ///
    /// ── Why not `isoDay` ──
    ///
    /// A bare day is UTC midnight to `new Date`, so «до 9 октомври» sent as
    /// `2026-10-09` would end the range at 03:00 on the 9th in Sofia and drop
    /// the rest of that day. So the app works the day's edges out in the
    /// device's time zone and sends them as instants.
    ///
    /// Milliseconds because the upper bound is INCLUSIVE (`lte`) and the
    /// column keeps them. The last moment of a day is `…:59.999`; to the
    /// second, an entry made in the day's final second would be dropped.
    ///
    /// ── Rounded to the millisecond, then written from integers ──
    ///
    /// `ISO8601FormatStyle(includingFractionalSeconds:)` TRUNCATES, and a
    /// `Double` holds `…:59.999` as `…:59.998999…`, so the style wrote
    /// `.998` (measured 2026-10-10). That would drop the day's last
    /// millisecond. So the instant is rounded to whole milliseconds; the
    /// seconds are written by the style, which is exact for whole seconds,
    /// and the milliseconds are appended as digits.
    static func isoInstant(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var (seconds, fraction) = ms.quotientAndRemainder(dividingBy: 1000)
        // Before 1970 the remainder is negative; the seconds round down.
        if fraction < 0 { seconds -= 1; fraction += 1000 }
        // UTC, `.iso8601`'s default: `2026-10-09T20:59:59Z`, so the `Z` the
        // server writes is the `Z` it reads back.
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
        // `1000 + fraction` is four digits; dropping the 1 pads to three.
        let digits = String(String(1000 + fraction).dropFirst())
        return "\(whole.dropLast()).\(digits)Z"
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

    /// A timestamp from a RESPONSE schema that may not pin a format.
    ///
    /// ── Why this is not `parseISODay`, and not a `Date` property either ──
    ///
    /// The parcel-history contract WAS asymmetric, read from the generated
    /// spec rather than from anybody's memory of it (fetched 2026-09-25):
    ///
    ///     CreateParcelCropSeason.sownAt        string, format: date-time
    ///     ParcelCropSeason.sownAt              string, NO format
    ///     CreateParcelWeedObservation.observedAt   string, format: date-time
    ///     ParcelWeedObservation.observedAt     string, NO format
    ///
    /// Those reads pin `date-time` now (checked 2026-10-08, agrent-ios#182),
    /// and this parser accepts exactly that. It stays the one path for every
    /// such read because others still pin nothing — `AgDashboardJournalItem
    /// .occurredAt`, `AgDashboardTaskItem.dueAt`, `ParcelRisk.generatedAt` —
    /// and one parser for all of them is simpler than two styles of date.
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
        return parseInstant(string) ?? parseISODay(string)
    }

    /// An instant as the server writes it — `2026-09-18T07:12:00.000Z` — with
    /// or without the fraction, and with an offset in place of the `Z`.
    /// `APIClient`'s decoder reads every `Date` through this, so there is one
    /// spelling of "an instant" in the app.
    ///
    /// `Date.ISO8601FormatStyle`, not `ISO8601DateFormatter` (P4.6, #195): a
    /// format style is a `Sendable` value, so the decoder's `@Sendable`
    /// strategy can hold it, and so can a `static let`; the formatter class
    /// could be neither under Swift 6. `InstantParsingTests` pins it to the
    /// old formatter's answers on the server's spellings and the edge cases.
    static func parseInstant(_ string: String) -> Date? {
        (try? instantWithFraction.parse(string)) ?? (try? instant.parse(string))
    }

    /// Two styles, because fractional seconds are all-or-nothing in either
    /// API: one REQUIRES them, the other REFUSES them. `.colon` because an
    /// offset is written `+03:00`; the `Z` the server sends parses either way.
    private static let instantWithFraction =
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)

    private static let instant = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
