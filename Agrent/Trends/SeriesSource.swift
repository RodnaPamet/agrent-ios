import Foundation

/// Where a price comes from, in Bulgarian: the one info row under Тенденции's
/// chart and the line under Табло's price (#409, owner 2026-10-23).
///
/// ── Never the feed's English ──
///
/// The EC agri-food feed names its stages in English prose and codes:
/// «National Average - Not Specified», «Burgas - DEPPROD», «Departure from
/// farm or from production area - on truck or other transport means». The
/// legend printed them as they came, which is what the owner's screenshot
/// showed. So this recognises what the feeds send and says it in Bulgarian,
/// and anything it does not recognise is LEFT OUT rather than shown: the
/// region alone is true, where an untranslated sentence on a Bulgarian screen
/// is the defect this replaces.
///
/// ── Recognised loosely, the way the web does ──
///
/// EC has renamed its stages once already (agri-saas `trends-helpers.ts`,
/// `isNationalAverage`): the market moved out of the stage name, which
/// orphaned ten Bulgarian wheat series. A literal match would break on the
/// next rename; a case-insensitive substring survives one.
enum SeriesSource {
    /// «Средна за България», «Бургас», «България · с данъци и акциз»,
    /// «Въведена от Agrent». Shown joined by «·»; spoken from `parts`, since
    /// VoiceOver reads the interpunct aloud.
    static func name(of series: PriceSeries) -> String {
        parts(of: series).joined(separator: " · ")
    }

    static func parts(of series: PriceSeries) -> [String] {
        if series.isPlatformPrice { return ["Въведена от Agrent"] }
        let region = SeriesVocabulary.region(series.region)
        if isNationalAverage(series) { return ["Средна за \(region)"] }
        if series.source == listingsSource { return ["Обявите в Agrent"] }
        if let stage = stage(series.stage) { return stage.standsAlone ? [stage.text] : [region, stage.text] }
        // No stage worth naming: the instrument, when the server already
        // said it in Bulgarian (`localiseSeriesLabel`, agri-saas), else just
        // the region.
        if let label = series.label, UserMessage.isBulgarianSentence(label) || isCyrillicWord(label) {
            return [region, label]
        }
        return [region]
    }

    /// The country-wide figure EC publishes beside its delivery points: the
    /// answer to "what is wheat worth in Bulgaria", and the one the chart
    /// draws when it exists.
    static func isNationalAverage(_ series: PriceSeries) -> Bool {
        (series.stage ?? "").lowercased().contains("national average")
    }

    static let listingsSource = "listings"
    static let ecSource = "ec-agrifood"

    private struct Stage {
        let text: String
        /// A delivery point names a place in Bulgaria already, so «Бургас»
        /// rather than «България · Бургас».
        let standsAlone: Bool
    }

    private static func stage(_ raw: String?) -> Stage? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        // The oil bulletin's two tax bases, which `SeriesVocabulary` names.
        if let known = SeriesVocabulary.stage(raw), known != raw { return Stage(text: known, standsAlone: false) }
        for (fragment, text) in phrases where lower.contains(fragment) {
            return Stage(text: text, standsAlone: false)
        }
        // «Burgas - DEPPROD»: a market, then EC's code for the stage.
        if let dash = raw.range(of: " - ") {
            let market = raw[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            if let city = cities[market.lowercased()] { return Stage(text: city, standsAlone: true) }
        }
        if let city = cities[lower] { return Stage(text: city, standsAlone: true) }
        return nil
    }

    /// EC's stages, by what they say rather than how they are spelled this
    /// year. «Франко» is the trade term a Bulgarian buyer quotes in.
    private static let phrases: [(String, String)] = [
        ("departure from farm", "франко стопанство"),
        ("fgate", "франко стопанство"),
        ("farm gate", "франко стопанство"),
        ("exw", "франко склад"),
        ("depsilo", "франко силоз"),
        ("depport", "франко пристанище"),
        ("delivered to port", "франко пристанище"),
    ]

    /// The delivery points EC quotes in Bulgaria, and the other district
    /// centres, so a new one reads in Bulgarian on the day it appears.
    private static let cities: [String: String] = [
        "burgas": "Бургас", "dobrich": "Добрич", "varna": "Варна", "ruse": "Русе",
        "pleven": "Плевен", "plovdiv": "Пловдив", "stara zagora": "Стара Загора",
        "sofia": "София", "silistra": "Силистра", "shumen": "Шумен", "vidin": "Видин",
        "montana": "Монтана", "vratsa": "Враца", "yambol": "Ямбол", "haskovo": "Хасково",
        "sliven": "Сливен", "targovishte": "Търговище", "razgrad": "Разград",
        "lovech": "Ловеч", "veliko tarnovo": "Велико Търново", "gabrovo": "Габрово",
        "pazardzhik": "Пазарджик", "kardzhali": "Кърджали", "smolyan": "Смолян",
        "blagoevgrad": "Благоевград", "kyustendil": "Кюстендил", "pernik": "Перник",
    ]

    /// One Cyrillic word («Пшеница») is not a sentence, but it is Bulgarian.
    private static func isCyrillicWord(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}
