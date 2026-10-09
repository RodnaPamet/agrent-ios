import Foundation

/// What the Дневник is narrowed to: type, crop, block and period (owner,
/// 2026-10-09: «add filter to journal (on date, crop, block, journal type)»,
/// agrent-ios#252).
///
/// ── The server filters, not the phone ──
///
/// A list row carries id, type, status, title and date. It has no crop and no
/// block, so the phone has nothing to match them against. The list also
/// arrives fifty at a time, so a filter applied here would narrow only the
/// pages already fetched and present them as the whole diary. The journal
/// route takes all four as query parameters (`JournalQuerySchema`), and this
/// type writes them. The spec documents none of them, so they were read from
/// the route and its repository on agri-saas main, 2026-10-09.
///
/// ── What each one matches, on the server ──
///
///     type          the entry's own type
///     crop          entries written from an operation line on a parcel whose
///                   `cropType` is one of the values; a free-hand entry has
///                   no line, so it never matches
///     locationId    entries linked to the block (`LogLocation`), and the
///                   operations on its parcels once backend 1 widens it; see
///                   agrent-ios#252
///     occurredFrom / occurredTo   inclusive instants on `occurredAt`
struct JournalFilter: Equatable, Sendable {
    var type: LogEntryType?
    var crop: Crop?
    var block: Block?
    var period: Period = .any

    /// The chosen days when `period` is `.custom`. They are kept when another
    /// period is picked, so going back to «Избран период» finds them again.
    var customFrom: Date
    var customTo: Date

    /// Unfiltered, with a chosen range ready at the last 30 days.
    init(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        customTo = today
        customFrom = calendar.date(byAdding: .day, value: -29, to: today) ?? today
    }

    var isActive: Bool { type != nil || crop != nil || block != nil || period != .any }

    /// A crop as the filter offers it: one name a person reads, and every
    /// spelling the farm's parcels store under that name. See `options(from:)`.
    struct Crop: Hashable, Sendable {
        let label: String
        let values: [String]
    }

    /// A block: the server's `Location`, which the web describes as
    /// «Земеделски блокове и техните парцели». A farmer uploads a shapefile
    /// into one, and its parcels are the shapes inside.
    struct Block: Hashable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    enum Period: String, CaseIterable, Identifiable, Sendable {
        case any, last30Days, thisYear, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            // The web's own word for no date filter (`ui.filter.anyDate`).
            case .any: "Всяка дата"
            case .last30Days: "Последните 30 дни"
            case .thisYear: "Тази година"
            case .custom: "Избран период"
            }
        }
    }

    // MARK: - The period as instants

    /// The period as two inclusive instants, either of which may be open.
    /// The day's edges are worked out in the device's time zone, so «до 9
    /// октомври» runs to the last millisecond of the 9th in Sofia, not in UTC.
    /// `now` and `calendar` are parameters so a test can hold them.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .any:
            return (nil, nil)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -29, to: today), Self.lastMoment(of: today, calendar))
        case .thisYear:
            // The whole calendar year, planned entries later in it included.
            guard let year = calendar.dateInterval(of: .year, for: now) else { return (nil, nil) }
            return (year.start, year.end.addingTimeInterval(-0.001))
        case .custom:
            // Ordered here rather than trusted. The sheet keeps «От» before
            // «До», but a filter is a value anyone can build.
            let first = min(customFrom, customTo), last = max(customFrom, customTo)
            return (calendar.startOfDay(for: first), Self.lastMoment(of: last, calendar))
        }
    }

    /// The day's last millisecond. The server compares with `lte` and keeps
    /// milliseconds, so this is the latest instant still inside the day.
    private static func lastMoment(of day: Date, _ calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001)
    }

    // MARK: - The query

    /// The query in the route's own names, with every value percent-encoded,
    /// because `APIClient.url(for:)` takes a query verbatim. Empty when
    /// nothing is filtered, so the unfiltered path stays byte for byte the
    /// one the cache and the fixtures know.
    func query(now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let type { parts.append("type=" + URLEscape.queryValue(type.rawValue)) }
        // One comma-separated value, which the route splits (`csvIdField`).
        // The comma is encoded with the rest and decoded before the split.
        if let crop, !crop.values.isEmpty {
            parts.append("crop=" + URLEscape.queryValue(crop.values.joined(separator: ",")))
        }
        if let block { parts.append("locationId=" + URLEscape.queryValue(block.id)) }
        let (from, to) = bounds(now: now, calendar: calendar)
        if let from { parts.append("occurredFrom=" + URLEscape.queryValue(BgDate.isoInstant(from))) }
        if let to { parts.append("occurredTo=" + URLEscape.queryValue(BgDate.isoInstant(to))) }
        return parts.joined(separator: "&")
    }

    // MARK: - An entry the phone just wrote

    /// Whether an entry this phone has just written belongs on the filtered
    /// list. `JournalStore.create` puts it at the top only when it does.
    /// Otherwise the operator would see a row the server would never return
    /// for this filter, and it would vanish on the next refresh.
    ///
    /// The phone writes free-hand entries: no operation line and no link to
    /// a block. Neither the crop filter nor the block filter can match one,
    /// so either facet rules it out. Type and period are checked the way the
    /// server checks them.
    func admits(_ entry: LogEntry, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if crop != nil || block != nil { return false }
        if let type, entry.type != type { return false }
        let (from, to) = bounds(now: now, calendar: calendar)
        guard from != nil || to != nil else { return true }
        guard let at = entry.occurredAt else { return false }
        if let from, at < from { return false }
        if let to, at > to { return false }
        return true
    }

    // MARK: - Said back to the reader

    /// What the list is narrowed to, one «name: value» phrase per facet, in
    /// the sheet's order.
    func facts(now: Date = Date(), calendar: Calendar = .current) -> [String] {
        var facts: [String] = []
        if let type { facts.append("Тип: \(type.label)") }
        if let crop { facts.append("Култура: \(crop.label)") }
        if let block { facts.append("Блок: \(block.name)") }
        if let period = periodText(now: now, calendar: calendar) { facts.append("Период: \(period)") }
        return facts
    }

    /// The period as a reader says it: the preset's name, or the chosen days,
    /// with the year only when it is not this one (`BgDate.rowDay`).
    func periodText(now: Date = Date(), calendar: Calendar = .current) -> String? {
        switch period {
        case .any:
            return nil
        case .last30Days, .thisYear:
            return period.label
        case .custom:
            let first = min(customFrom, customTo), last = max(customFrom, customTo)
            let from = BgDate.rowDay(first, now: now, calendar: calendar)
            if calendar.isDate(first, inSameDayAs: last) { return from }
            return "\(from) – \(BgDate.rowDay(last, now: now, calendar: calendar))"
        }
    }
}

extension JournalFilter.Crop {
    /// The crops on the farm's parcels, one per name a person reads.
    ///
    /// ── Every stored spelling, because the server matches exactly ──
    ///
    /// `cropType` is free text, and the filter is `cropType IN (…)`: exact and
    /// case-sensitive. The web's picker writes `Wheat`; an import or an older
    /// client may have written `wheat`. Grouping the spellings under the name
    /// shown (`CommodityName.freeText`) and sending all of them means
    /// «Пшеница» finds both. Any single spelling would quietly miss the other
    /// one's entries.
    ///
    /// ── Spellings the route cannot carry are left out ──
    ///
    /// The route splits the value on commas, trims each part, and refuses a
    /// part over 200 characters (`csvIdField`). So `Grass, ley`, ` Wheat`, or a
    /// 201-character name could never match, and sending one would ask for
    /// something else.
    static func options(from parcels: [Parcel]) -> [JournalFilter.Crop] {
        options(from: parcels.map(\.cropType))
    }

    static func options(from cropTypes: [String?]) -> [JournalFilter.Crop] {
        var spellings: [String: [String]] = [:]
        for case let raw? in cropTypes where isSendable(raw) {
            guard let label = CommodityName.freeText(raw) else { continue }
            if spellings[label]?.contains(raw) != true { spellings[label, default: []].append(raw) }
        }
        return spellings
            .map { JournalFilter.Crop(label: $0.key, values: $0.value.sorted()) }
            .sorted { $0.label.compare($1.label, locale: BgDate.locale) == .orderedAscending }
    }

    static func isSendable(_ raw: String) -> Bool {
        !raw.isEmpty && raw.count <= 200 && !raw.contains(",")
            && raw == raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension JournalFilter.Block {
    /// The farm's blocks: its FIELD locations. A bin or a store is a location
    /// too, but it is not a block of parcels. A location with no `kind` is a
    /// field, the server's default. The key can be absent; see `Location.kind`.
    static func options(from locations: [Location]) -> [JournalFilter.Block] {
        locations
            .filter { $0.kind == nil || $0.kind == "FIELD" }
            .map { JournalFilter.Block(id: $0.id, name: $0.name) }
    }
}
