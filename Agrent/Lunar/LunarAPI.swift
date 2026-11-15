import Foundation

/// «Лунен календар» (#611, owner 2026-11-15): the Moon's phase and sidereal
/// sign for each day, and the folk tradition's advice for the owner's three
/// crop groups. Contract: agri-saas #3070 §2, route in #3073.
///
/// ── Tradition, not advice ──
///
/// The owner's framing: shown «По лунния календар», never as agronomic
/// advice, never on ДНЕВНИК. The server computes the days (sidereal, so a
/// tropical almanac disagrees about 80% of the time; that is the tradition,
/// not a bug) and sends KEYS, never sentences; `LunarWords` holds the words.
///
/// ── Not a farm's data ──
///
/// `/api/lunar` names no farm: the Moon is the same over every farm, and it
/// works before a person has one. Behind `lunar.enabled`; a 404 is the flag
/// off. Deterministic, so the same range is the same bytes for ever.
///
/// ── Sowing is held back on a warning day ──
///
/// Owner, 2026-11-15: no sowing advice on a day when a block has a frost or
/// spray warning, and the calendar waits until the phone can tell
/// (`LunarWarnings`).
enum LunarAPI {
    static let flag = "lunar.enabled"
    /// The server refuses a wider span.
    static let maxDays = 62

    static func path(from: Date, to: Date, calendar: Calendar = FarmRecordAPI.farmCalendar) -> String {
        "/api/lunar?from=\(BgDate.isoDay(from, in: calendar))&to=\(BgDate.isoDay(to, in: calendar))"
    }

    /// One calendar month in the farm's zone: its first and last day.
    static func month(containing day: Date, calendar: Calendar = FarmRecordAPI.farmCalendar) -> (from: Date, to: Date) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
        let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
        return (start, end)
    }

    static func load(from: Date, to: Date) async throws -> [LunarDay] {
        let data = try await APIClient.shared.data(for: path(from: from, to: to))
        return try await APIClient.shared.decode(data, as: LunarPage.self).days
    }
}

struct LunarPage: Decodable, Sendable {
    let days: [LunarDay]
}

/// One farm-local day. Every vocabulary is read as a plain string: a value
/// the phone does not know yet is shown as nothing, never a failed page.
struct LunarDay: Decodable, Identifiable, Equatable, Hashable, Sendable {
    /// `YYYY-MM-DD` in Europe/Sofia.
    let date: String
    let phase: String
    let phaseName: String
    let illumination: Double
    let sign: String
    let element: String
    /// At farm-local NOON; `transitions` says when the day changes type.
    let dayType: String
    let transitions: [Transition]
    let recommendations: Recommendations
    var id: String { date }

    struct Transition: Decodable, Equatable, Hashable, Sendable {
        let at: Date
        let toSign: String
        let toDayType: String
    }

    /// Keys per crop group; unknown keys are kept here and dropped when
    /// worded (`LunarWords.advice`).
    struct Recommendations: Decodable, Equatable, Hashable, Sendable {
        let field: [String]
        let vegetable: [String]
        let perennial: [String]

        private enum CodingKeys: String, CodingKey { case field, vegetable, perennial }
        init(field: [String], vegetable: [String], perennial: [String]) {
            self.field = field
            self.vegetable = vegetable
            self.perennial = perennial
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            field = (try? c.decodeIfPresent([String].self, forKey: .field)) ?? []
            vegetable = (try? c.decodeIfPresent([String].self, forKey: .vegetable)) ?? []
            perennial = (try? c.decodeIfPresent([String].self, forKey: .perennial)) ?? []
        }

        func keys(_ group: LunarWords.Group) -> [String] {
            switch group {
            case .field: field
            case .vegetable: vegetable
            case .perennial: perennial
            }
        }
    }

    /// The day as a date, in the farm's zone.
    func day(calendar: Calendar = FarmRecordAPI.farmCalendar) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// Frost and spray warnings by day: how many blocks have one. Empty until
/// the farm's signals can be read (#611); the calendar ships only then.
struct LunarWarnings: Equatable, Sendable {
    var blocksByDay: [String: Int] = [:]

    func blocks(on date: String) -> Int { blocksByDay[date] ?? 0 }
}
