import Foundation

/// «Агрономически календар» (#633, owner 2026-11-15/16): for each crop,
/// when to sow, the main field work by stage, and when it is harvested, for
/// North or South Bulgaria. Every window names its SOURCE (owner: publish
/// with sources, correct afterwards); the field crops come from МЗХ's
/// integrated-production guide (2024) and its weekly bulletins (#636).
///
/// ── From the server ──
///
/// `GET /api/agro-calendar?region=` (agri-saas #3094, live 2026-11-16),
/// person-scoped like `/api/lunar`: a correction needs no release. It was
/// bundled in the app for the first build (154.1); the bundled copy is gone
/// now that the server serves the same bytes. Read leniently: an entry it
/// cannot read is left out, never the whole calendar.
struct AgroCalendar: Decodable, Equatable, Sendable {
    let compiledAt: String?
    let sources: [String: Source]
    let crops: [Crop]

    struct Source: Decodable, Equatable, Sendable {
        let title: String
        let publisher: String?
        let url: String?
        /// `YYYY` or `YYYY-MM`.
        let published: String?
    }

    /// A source as cited by one window: which document, and its page.
    ///
    /// The page is a number, or a string where the source cites a span
    /// («20–21»), as agri-saas's `AgroCalendarCitation` allows; both are
    /// shown as written.
    struct Citation: Decodable, Equatable, Hashable, Sendable {
        let source: String
        let page: String?

        private enum CodingKeys: String, CodingKey { case source, page }
        init(source: String, page: String?) {
            self.source = source
            self.page = page
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            if let number = try? c.decodeIfPresent(Int.self, forKey: .page) {
                page = String(number)
            } else {
                page = try? c.decodeIfPresent(String.self, forKey: .page)
            }
        }
    }

    /// `{min, max, unit}` with the unit always named: `seeds/m2`,
    /// `plants/da`, `plants/m2`, `cm`. Never converted here.
    struct Amount: Decodable, Equatable, Hashable, Sendable {
        let min: Double
        let max: Double
        let unit: String
    }

    struct Text: Decodable, Equatable, Hashable, Sendable {
        let bg: String?
    }

    struct Crop: Decodable, Identifiable, Equatable, Sendable {
        let key: String
        let group: String
        let name: Text
        let windows: [Window]
        /// МЗХ's direct costs, only where МЗХ prices a card (agri-saas #3127:
        /// wine grapes, 2026). ABSENT on every other crop: МЗХ prices none.
        let costs: Costs?
        var id: String { key }

        private enum CodingKeys: String, CodingKey { case key, group, name, windows, costs }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            group = try c.decode(String.self, forKey: .group)
            name = try c.decode(Text.self, forKey: .name)
            windows = (try? c.decodeIfPresent(Lenient<Window>.self, forKey: .windows))?.values ?? []
            // A costs block that does not read is left out, never the crop.
            costs = try? c.decodeIfPresent(Costs.self, forKey: .costs)
        }

        var title: String { name.bg ?? key }

        func windows(_ kind: Window.Kind, in region: AgroRegion) -> [Window] {
            windows.filter { $0.kind == kind && $0.applies(to: region) }
        }
    }

    /// A card's direct costs per decare, in euro cents the SERVER converted
    /// (owner, 2026-11-16: МЗХ's лв figures at the euro peg, marked
    /// «превалутирано»; the phone holds no peg). The лв figures as printed
    /// are the server's to keep; only euro is shown (EUR only, 2026-11-06).
    struct Costs: Decodable, Equatable, Sendable {
        let cite: Citation
        let lines: [Line]
        let perDaEurCentsTotal: Int?

        struct Line: Decodable, Equatable, Sendable {
            let key: String
            let perDaEurCents: Int?
        }
    }

    /// A span of the year, `MM-DD` to `MM-DD`; `from` after `to` wraps New
    /// Year. Every window is cited: one without `cite` is not read.
    struct Window: Decodable, Identifiable, Equatable, Hashable, Sendable {
        enum Kind: String, Decodable, Sendable { case sowing, fieldwork, harvest }
        let id: String
        let kind: Kind
        let band: String?
        let region: String
        let from: String
        let to: String
        let seedRate: Amount?
        let depth: Amount?
        let title: Text?
        let note: Text?
        /// Never empty: the first is the window's own source.
        let citations: [Citation]
        var cite: Citation { citations[0] }

        /// The file writes `cite` and `alsoCite`; the API (agri-saas #3094)
        /// sends them together as `cites`. Either is read.
        private enum CodingKeys: String, CodingKey {
            case id, kind, band, region, from, to, seedRate, depth, title, note, cite, alsoCite, cites
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            band = try? c.decodeIfPresent(String.self, forKey: .band)
            region = (try? c.decodeIfPresent(String.self, forKey: .region)) ?? "both"
            from = try c.decode(String.self, forKey: .from)
            to = try c.decode(String.self, forKey: .to)
            seedRate = try? c.decodeIfPresent(Amount.self, forKey: .seedRate)
            depth = try? c.decodeIfPresent(Amount.self, forKey: .depth)
            title = try? c.decodeIfPresent(Text.self, forKey: .title)
            note = try? c.decodeIfPresent(Text.self, forKey: .note)
            if let cites = try? c.decodeIfPresent([Citation].self, forKey: .cites), !cites.isEmpty {
                citations = cites
            } else {
                let cite = try c.decode(Citation.self, forKey: .cite)
                citations = [cite] + ((try? c.decodeIfPresent([Citation].self, forKey: .alsoCite)) ?? [])
            }
        }

        /// Its own region's windows, and those for both.
        func applies(to region: AgroRegion) -> Bool {
            self.region == "both" || self.region == region.rawValue
        }

    }

    /// Reads a list, keeping the entries that read: an uncited or
    /// unreadable window is left out, never the whole calendar.
    private struct Lenient<T: Decodable>: Decodable {
        let values: [T]
        init(from decoder: any Decoder) throws {
            var list = try decoder.unkeyedContainer()
            var out: [T] = []
            while !list.isAtEnd {
                if let value = try? list.decode(T.self) { out.append(value) } else { _ = try? list.decode(Skip.self) }
            }
            values = out
        }
        private struct Skip: Decodable {}
    }

    func crops(in group: AgroGroup) -> [Crop] { crops.filter { $0.group == group.rawValue } }
}

enum AgroRegion: String, CaseIterable, Identifiable, Sendable {
    case north, south
    var id: String { rawValue }

    /// The half the farm's blocks lie in, to open the calendar on (owner,
    /// 2026-11-16): only when every block the server could place agrees.
    /// Blocks in both halves, or none placed, give no default.
    static func of(_ locations: [Location]) -> AgroRegion? {
        let placed = Set(locations.compactMap(\.agroRegion))
        return placed.count == 1 ? placed.first : nil
    }
    var title: String {
        switch self {
        case .north: "Северна България"
        case .south: "Южна България"
        }
    }
    var short: String {
        switch self {
        case .north: "Север"
        case .south: "Юг"
        }
    }
}

/// The owner's three groups, as «Лунен календар» names them.
enum AgroGroup: String, CaseIterable, Identifiable, Sendable {
    case field, vegetable, perennial
    var id: String { rawValue }
    var title: String {
        switch self {
        case .field: "Полски култури"
        case .vegetable: "Зеленчукови"
        case .perennial: "Трайни насаждения"
        }
    }
}

enum AgroWords {
    static let title = "Агрономически календар"
    static let calendars = "Календари"
    static let sowing = "Сеитба"
    static let seeding = "Норма и дълбочина"
    static let works = "Основни работи"
    static let harvest = "Прибиране"
    static let sources = "Източници"
    // МЗХ's costs (#637), the card's own words (agri-saas #3127 catalogue).
    static let costsTitle = "Разходи по МЗХ"
    static let costTotal = "Общо преки разходи"
    static let costLabels: [String: String] = [
        "fuel": "Горива",
        "materials": "Материали, препарати за растителна защита и торове",
        "wagesWorkers": "Заплати и осигуровки на работниците",
        "wagesMachineOperators": "Заплати и осигуровки на механизаторите",
        "services": "Услуги",
    ]

    /// «21,36 EUR на дка».
    static func perDa(_ cents: Int) -> String { "\(InsurancePremium.eur(cents)) на дка" }

    /// «по МЗХ (2026), превалутирано», the owner's marker (2026-11-16), word
    /// for word: no lev figure and no rate on screen (EUR only).
    static func costsNote(year: String?) -> String {
        "по МЗХ\(year.map { " (\($0))" } ?? ""), превалутирано"
    }

    static let nowBadge = "Сега"
    static let depth = "Дълбочина"

    /// What is due now for a crop in a region, for its row: «Сега: сеитба».
    static func now(_ crop: AgroCalendar.Crop, in region: AgroRegion, today: Date = Date()) -> String? {
        let due = [(AgroCalendar.Window.Kind.sowing, "сеитба"), (.harvest, "прибиране"), (.fieldwork, "работи по културата")]
            .filter { kind, _ in crop.windows(kind, in: region).contains { isNow($0.from, $0.to, today: today) } }
            .map(\.1)
        return due.isEmpty ? nil : "Сега: " + due.joined(separator: ", ")
    }
    static let notice = "Сроковете са ориентировъчни, по официални и научни източници. Времето и сортът могат да ги изместят."

    /// «25 септември – 10 октомври» from `MM-DD` keys; nil for a key that
    /// does not read.
    static func span(_ from: String, _ to: String) -> String? {
        guard let start = day(from), let end = day(to) else { return nil }
        return "\(BgDate.dayMonth(start)) – \(BgDate.dayMonth(end))"
    }

    /// A `MM-DD` key as a date in a fixed non-leap year, for its words only.
    static func day(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia") ?? .current
        return calendar.date(from: DateComponents(year: 2001, month: parts[0], day: parts[1], hour: 12))
    }

    /// Whether `today` falls inside a window, across New Year too.
    static func isNow(_ from: String, _ to: String, today: Date = Date(), calendar: Calendar = FarmRecordAPI.farmCalendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: today)
        let now = String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
        return from <= to ? (from...to).contains(now) : (now >= from || now <= to)
    }

    /// «МЗХ, 2024, стр. 20» for a citation.
    static func cite(_ citation: AgroCalendar.Citation, in calendar: AgroCalendar) -> String? {
        guard let source = calendar.sources[citation.source] else { return nil }
        var parts = [source.publisher ?? source.title]
        if let year = source.published?.prefix(4) { parts.append(String(year)) }
        if let page = citation.page { parts.append("стр. \(page)") }
        return parts.joined(separator: ", ")
    }

    /// «500–600 кълняеми семена на м²», «4–6 см»: the unit as named, never
    /// converted. An unknown unit is shown as sent.
    static func amount(_ amount: AgroCalendar.Amount) -> String {
        let range = amount.min == amount.max ? number(amount.min) : "\(number(amount.min))–\(number(amount.max))"
        return "\(range) \(units[amount.unit] ?? amount.unit)"
    }

    static let units = [
        "seeds/m2": "кълняеми семена на м²",
        "plants/m2": "растения на м²",
        "plants/da": "растения на декар",
        "kg/da": "кг на декар",
        "cm": "см",
    ]

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : Num.text(value)
    }
}
