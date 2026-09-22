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

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
