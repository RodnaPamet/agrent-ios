import Foundation

enum NewsCategory: String, CaseIterable, Identifiable, Sendable {
    case all, market, policy, general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Всички"
        case .market: "Пазар"
        case .policy: "Политика"
        case .general: "Общи"
        }
    }
}

struct NewsItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let source: String
    /// A STRING, not `NewsCategory`.
    ///
    /// The three known values are the filter vocabulary, and a fourth
    /// added server-side must not fail the decode of the whole list —
    /// which, because this is non-optional inside an array, is what an
    /// enum here would do. Same lesson as `LogEntryType`, where six client
    /// cases against the server's ten meant the first unrecognised entry
    /// would have taken every row with it.
    let category: String
    let title: String
    let summary: String?
    let url: String
    let imageUrl: String?
    /// A real instant here, unlike the price dates.
    let publishedAt: Date

    var link: URL? { URL(string: url) }

    var categoryLabel: String? {
        NewsCategory(rawValue: category).map(\.label)
    }

    /// The summary with the feed's own footer taken off.
    ///
    /// Both syndicated feeds append an attribution sentence after a
    /// newline, and it is on every single item:
    ///
    ///     …вършели 9,4 милиона хектара...
    ///     Материалът <title> е публикуван за пръв път на Агровест.
    ///
    ///     …селския и […]
    ///     Публикация <title> се показа за първи път в AGRO TV | Телевиз
    ///
    /// It repeats the headline the reader has just read, names the source
    /// already shown beside it, and on a phone it is often the only part
    /// of the summary still visible after truncation — so the two lines a
    /// farmer sees are the title twice.
    ///
    /// Matched on the ATTRIBUTION PHRASE, not on the opening word.
    ///
    /// The first version keyed on the prefixes `"Материалът "` and
    /// `"Публикация "` and deleted any line starting with either. A test
    /// caught what that does to a real sentence:
    ///
    ///     "Публикация в Държавен вестник промени сроковете."
    ///
    /// — a summary about a gazette notice, removed in full, leaving the
    /// item with no summary at all. The comment above it already claimed
    /// the match was narrow; the code was not, and only running it said so.
    ///
    /// `"е публикуван за пръв път"` and `"се показа за първи път"` are the
    /// phrases the feeds actually use and are specific enough to be safe
    /// anywhere in a line. If the server strips this at ingest, this
    /// becomes a no-op rather than a conflict.
    var cleanedSummary: String? {
        guard let summary else { return nil }
        let attributions = ["е публикуван за пръв път", "се показа за първи път"]
        let kept = summary
            .components(separatedBy: .newlines)
            .filter { line in !attributions.contains { line.contains($0) } }
        let text = kept.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct NewsResponse: Decodable, Equatable, Sendable {
    let category: String
    let items: [NewsItem]
}

enum TrendsAPI {
    static func pricesPath(_ commodity: ChartableCommodity, range: PriceRange) -> String {
        "/api/t/\(Config.tenantSlug)/trends/prices"
            + "?commodity=\(commodity.rawValue)&range=\(range.rawValue)"
    }

    /// `limit` is 1…100 server-side. 50 is its own default and is more
    /// than a phone will scroll in one sitting.
    static func newsPath(_ category: NewsCategory, limit: Int = 50) -> String {
        var path = "/api/t/\(Config.tenantSlug)/trends/news?limit=\(min(max(limit, 1), 100))"
        if category != .all { path += "&category=\(category.rawValue)" }
        return path
    }
}

/// Names for the parts of a series that production returns as codes.
///
/// `stage` is heterogeneous — `"without-tax"` from the oil bulletin and
/// `"Burgas - DEPPROD"` from the EC agri-food feed — so this is the same
/// shape as `ApplicationTechnique`: translate what is recognised, pass
/// through what is not. Inventing a Bulgarian rendering of an unknown code
/// would be worse than showing the code.
enum SeriesVocabulary {
    static func stage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "with-tax": return "с данъци и акциз"
        case "without-tax": return "без данъци и акциз"
        default: return raw
        }
    }

    /// A chart heading a Bulgarian farmer can read.
    ///
    /// The feeds send the unit in English — `"dollar per metric ton"`,
    /// `"EUR/1000l"` — and the first build put it on screen verbatim above
    /// every chart. That is precisely the complaint the owner raised about
    /// crop names reading "wheat": server data rendered as a UI label
    /// because nothing that translates labels was ever going to reach it.
    ///
    /// Also drops the redundant currency. `"EUR/t · EUR"` says EUR twice,
    /// and the second one is the only part that was ever a separate field.
    static func unitHeading(unit: String, currency: String) -> String {
        let known: [String: String] = [
            "eur/t": "евро на тон",
            "eur/1000l": "евро на 1000 литра",
            "eur/100kg": "евро на 100 кг",
            "dollar per metric ton": "долар на тон",
            "usd/t": "долар на тон",
            "bgn/t": "лева на тон",
        ]
        if let named = known[unit.lowercased()] { return named }
        // Unknown unit: show it as sent, with the currency, because an
        // invented translation of a unit is a claim about what is being
        // measured. Same rule as an unrecognised stage.
        return unit.localizedCaseInsensitiveContains(currency)
            ? unit
            : "\(unit) · \(currency)"
    }

    static func region(_ raw: String) -> String {
        switch raw.uppercased() {
        case "BG": return "България"
        case "GLOBAL": return "Световен"
        case "EU": return "ЕС"
        case "EL", "GR": return "Гърция"
        case "RO": return "Румъния"
        case "DE": return "Германия"
        case "FR": return "Франция"
        case "HU": return "Унгария"
        case "PL": return "Полша"
        // Anything else keeps its ISO code. A code is neutral; a guessed
        // translation is a claim, and there are twenty-seven of them.
        default: return raw
        }
    }
}
