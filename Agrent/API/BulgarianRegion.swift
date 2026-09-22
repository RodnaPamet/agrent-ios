import Foundation

/// The 28 oblasti, by ISO 3166-2:BG code.
///
/// ── `regionName` ON THE WIRE IS ENGLISH ──
///
/// A listing carries `regionCode` AND `regionName`, and the name is
/// English — "Blagoevgrad", not "Благоевград". The web does not render it
/// either: it calls `localizedRegionName(code, locale, storedName)`, which
/// looks the code up and returns the Bulgarian, falling back to the stored
/// English and then to the bare code.
///
/// This is the `{commodity}` defect again — a server field that is an
/// IDENTITY doing duty as a label — and the third time today. So the code
/// is the identity and this table is the label, exactly as
/// `CommodityName` does it.
///
/// ── Taken, not written ──
///
/// The 28 names are the server's, verbatim. This app has twice stopped
/// itself inventing a vocabulary and once discovered it was about to
/// invent the first; the rule by now is that a name an operator reads
/// comes from one place.
///
/// Verified server-side as an exact join both ways: the 28 geometry `iso`
/// codes and the 28 catalogue codes match with no orphans in either
/// direction, so no listing can land in a region with no polygon.
enum BulgarianRegion {

    /// Bulgarian for a region code, falling back to the server's English
    /// name and then to the code itself.
    ///
    /// Three levels rather than two because both fallbacks are real: a
    /// code this build has not heard of still has an English name on the
    /// wire, and a listing with neither still has to render as something.
    static func name(code: String?, fallback: String? = nil) -> String? {
        guard let code else { return fallback }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return fallback }
        return names[trimmed] ?? fallback ?? trimmed
    }

    static let names: [String: String] = [
        "BG-01": "Благоевград",     "BG-15": "Плевен",
        "BG-02": "Бургас",          "BG-16": "Пловдив",
        "BG-03": "Варна",           "BG-17": "Разград",
        "BG-04": "Велико Търново",  "BG-18": "Русе",
        "BG-05": "Видин",           "BG-19": "Силистра",
        "BG-06": "Враца",           "BG-20": "Сливен",
        "BG-07": "Габрово",         "BG-21": "Смолян",
        "BG-08": "Добрич",          "BG-22": "София (столица)",
        "BG-09": "Кърджали",        "BG-23": "София (област)",
        "BG-10": "Кюстендил",       "BG-24": "Стара Загора",
        "BG-11": "Ловеч",           "BG-25": "Търговище",
        "BG-12": "Монтана",         "BG-26": "Хасково",
        "BG-13": "Пазарджик",       "BG-27": "Шумен",
        "BG-14": "Перник",          "BG-28": "Ямбол",
    ]
}
