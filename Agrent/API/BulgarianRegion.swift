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

    /// Bulgarian for a region known ONLY by its English name, or that name
    /// unchanged when it matches nothing.
    ///
    /// ── For the one payload that carries no code ──
    ///
    /// An inbox row (`ExchangeThreadSummary`) has `listingRegionName` and no
    /// `listingRegionCode`, so `name(code:)` cannot be reached from it. The
    /// web prints the English as sent; that is the defect `name(code:)`
    /// exists to fix, one screen along.
    ///
    /// The English is the server's `nameEn` (agri-saas
    /// `src/lib/geo/bulgaria-regions.ts`, stored on the listing at create),
    /// and the bundled map geometry carries the same 28 `iso`/`name` pairs —
    /// read against that file on 2026-09-30, «Sofia» and «Sofia City» and
    /// all. So the English is resolved to a code through the asset the app
    /// already ships, and the Bulgarian comes from `names` above, as for
    /// every other region label. No third vocabulary is written here.
    ///
    /// Exact match after trimming, case-insensitive. Anything else is shown
    /// as it came — a region with an English name is still a region.
    static func name(english: String?) -> String? {
        guard let english = english?.trimmingCharacters(in: .whitespacesAndNewlines),
              !english.isEmpty
        else { return nil }
        guard let code = codesByEnglishName[english.lowercased()] else { return english }
        return names[code] ?? english
    }

    /// Lowercased English name → code, from the bundled geometry. Empty if
    /// the asset is missing, which degrades to the English, not to a crash.
    static let codesByEnglishName: [String: String] = {
        struct File: Decodable {
            struct Entry: Decodable { let iso: String; let name: String? }
            let oblasti: [Entry]
        }
        guard let url = Bundle.main.url(forResource: "bg-map-geometry", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        var table: [String: String] = [:]
        for entry in file.oblasti {
            guard let name = entry.name else { continue }
            table[name.lowercased()] = entry.iso.uppercased()
        }
        return table
    }()

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
