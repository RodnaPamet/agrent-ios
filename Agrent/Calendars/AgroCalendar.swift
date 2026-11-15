import Foundation

/// «Агрономически календар» (#633, owner 2026-11-15/16): for each crop,
/// when to sow, the main field work by stage, and when it is harvested, for
/// North or South Bulgaria. Every window names its SOURCE (owner: publish
/// with sources, correct afterwards); the field crops come from МЗХ's
/// integrated-production guide (2024) and its weekly bulletins (#636).
///
/// ── Bundled for now ──
///
/// The dataset ships in the app (`agro-calendar.json`) so the first version
/// needs no server. The same file is meant to be served by agri-saas later,
/// so a correction will not need a release; the shape is the server's to
/// settle, and this type reads it leniently: an entry it cannot read is
/// left out, never the whole calendar.
struct AgroCalendar: Decodable, Sendable {
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
    struct Citation: Decodable, Equatable, Hashable, Sendable {
        let source: String
        let page: Int?
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
        var id: String { key }

        private enum CodingKeys: String, CodingKey { case key, group, name, windows }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            group = try c.decode(String.self, forKey: .group)
            name = try c.decode(Text.self, forKey: .name)
            windows = (try? c.decodeIfPresent(Lenient<Window>.self, forKey: .windows))?.values ?? []
        }

        var title: String { name.bg ?? key }

        func windows(_ kind: Window.Kind, in region: AgroRegion) -> [Window] {
            windows.filter { $0.kind == kind && $0.applies(to: region) }
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
        let cite: Citation
        let alsoCite: [Citation]?

        private enum CodingKeys: String, CodingKey {
            case id, kind, band, region, from, to, seedRate, depth, title, note, cite, alsoCite
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
            cite = try c.decode(Citation.self, forKey: .cite)
            alsoCite = try? c.decodeIfPresent([Citation].self, forKey: .alsoCite)
        }

        /// Its own region's windows, and those for both.
        func applies(to region: AgroRegion) -> Bool {
            self.region == "both" || self.region == region.rawValue
        }

        var citations: [Citation] { [cite] + (alsoCite ?? []) }
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

    static func bundled() -> AgroCalendar? {
        guard let url = Bundle.main.url(forResource: "agro-calendar", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgroCalendar.self, from: data)
    }

    func crops(in group: AgroGroup) -> [Crop] { crops.filter { $0.group == group.rawValue } }
}

enum AgroRegion: String, CaseIterable, Identifiable, Sendable {
    case north, south
    var id: String { rawValue }
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
    static let none = "Календарът не можа да се зареди."
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
