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

    /// A unit a Bulgarian farmer can read. Тенденции's chart heading, its
    /// VoiceOver label and Табло's price headline all come through here, so
    /// the screens cannot disagree about what a unit says.
    ///
    /// The feeds send the unit in English — `"dollar per metric ton"`,
    /// `"EUR/1000l"` — and the first build put it on screen verbatim above
    /// every chart. That is precisely the complaint the owner raised about
    /// crop names reading "wheat": server data rendered as a UI label
    /// because nothing that translates labels was ever going to reach it.
    ///
    /// Also drops the redundant currency. `"EUR/t · EUR"` says EUR twice,
    /// and the second one is the only part that was ever a separate field.
    /// Табло interpolated `currency/unit` itself and got «EUR/EUR/1000l» for
    /// diesel (#121) — the reason this is the ONE composer.
    ///
    /// Parsed by shape, not looked up: the server stores units "as reported,
    /// never normalised" (agri-saas `market-manual.schemas.ts`) and the
    /// currency half varies by member state. What production can send, per
    /// agri-saas `src/lib/market/*` and `jobs/market-prices-pull.ts`:
    ///
    ///     EC cereals, Barchart        EUR/t
    ///     EC oilseeds, own listings   <CUR>/t      BGN, RON, HUF, PLN …
    ///     EC Oil Bulletin (diesel)    EUR/1000l
    ///     World Bank (urea, DAP)      USD/mt
    ///     Alpha Vantage               its own phrase ("dollar per metric
    ///                                 ton"), or USD/t when it sends none
    ///     admin manual entry          anything ≤ 32 chars, e.g. BGN/1000l
    ///
    /// plus a bare `"t"` (the app's fixtures), which takes its currency from
    /// the separate field. The lookup table this replaced knew six spellings
    /// and showed urea as «USD/mt» and Romanian rapeseed as «RON/t».
    static func unitHeading(unit: String, currency: String) -> String {
        words(unit: unit, currency: currency, afterNumber: false)
    }

    /// The same words for after a price — «512 долара на тон», where the
    /// heading says «долар на тон». Bulgarian counts in the plural and a
    /// price is practically never exactly one, so this does not try to be
    /// clever about «1 долар».
    static func priceUnit(unit: String, currency: String) -> String {
        words(unit: unit, currency: currency, afterNumber: true)
    }

    private static func words(unit: String, currency: String, afterNumber: Bool) -> String {
        let field = currency.uppercased()
        if let shape = UnitShape(unit), let measure = measures[shape.measure] {
            // A unit whose OWN currency disagrees with the field means the
            // price is in one of them and nothing here can say which — so
            // it falls through to showing both as sent rather than picking.
            if shape.currency == nil || shape.currency == field {
                let name = currencyName(shape.currency ?? field, afterNumber: afterNumber)
                return "\(name) на \(measure)"
            }
        }
        // Unknown unit: show it as sent, with the currency, because an
        // invented translation of a unit is a claim about what is being
        // measured. Same rule as an unrecognised stage.
        return unit.localizedCaseInsensitiveContains(currency)
            ? unit
            : "\(unit) · \(currency)"
    }

    /// Keyed by the measure lowercased with spaces removed: the bulletin's
    /// own cell reads `1000 l`, the stored unit `1000l`.
    private static let measures: [String: String] = [
        "t": "тон",
        "mt": "тон",
        "ton": "тон",
        "tonne": "тон",
        "metricton": "тон",
        "1000l": "1000 литра",
        "100kg": "100 кг",
    ]

    /// «долар на тон», «лева на тон» — the wording the old table set for a
    /// heading. Only the dollar changes after a number: «евро» does not
    /// inflect and «лева» already is the counting form (the table used it
    /// for the heading too, and it stays for parity).
    /// A currency without a Bulgarian name here keeps its ISO code: «RON на
    /// тон» is neutral, a guessed «леи» is a claim (same rule as `region`).
    private static func currencyName(_ code: String, afterNumber: Bool) -> String {
        switch code {
        case "EUR": "евро"
        case "USD": afterNumber ? "долара" : "долар"
        case "BGN": "лева"
        default: code
        }
    }

    /// `<currency>/<measure>`, `<currency> per <measure>`, or a bare measure.
    private struct UnitShape {
        /// ISO code, uppercased; nil when the unit carries none.
        let currency: String?
        /// Lowercased, spaces removed — the `measures` key.
        let measure: String

        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let head: Substring?
            let tail: Substring
            if let slash = trimmed.firstIndex(of: "/") {
                head = trimmed[..<slash]
                tail = trimmed[trimmed.index(after: slash)...]
            } else if let per = trimmed.range(of: " per ", options: .caseInsensitive) {
                head = trimmed[..<per.lowerBound]
                tail = trimmed[per.upperBound...]
            } else {
                head = nil
                tail = Substring(trimmed)
            }
            measure = tail.lowercased().replacingOccurrences(of: " ", with: "")
            guard let head else { currency = nil; return }
            let token = head.trimmingCharacters(in: .whitespaces)
            switch token.lowercased() {
            case "dollar", "dollars", "us dollar", "$": currency = "USD"
            case "euro", "euros", "€": currency = "EUR"
            default:
                // Mixed case is the market convention for MINOR units —
                // `USd/bu` is US CENTS a bushel (commented out in agri-saas
                // `barchart-client.ts`, one uncomment from production).
                // Reading it as USD would be off by a hundred, so only an
                // all-upper or all-lower code counts as a currency.
                guard token.count == 3, token.allSatisfy(\.isLetter),
                      token == token.uppercased() || token == token.lowercased()
                else { return nil }
                currency = token.uppercased()
            }
        }
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
