import Foundation

/// Mirrors `LogEntryType` in **prisma/schema/enums.prisma**.
///
/// NOT `journal.prisma` — this comment said that and it was wrong, and the
/// wrong citation is why the enum was never checked against the real one. The
/// app shipped SIX cases against the server's TEN, and invented an `OTHER` the
/// server has never had:
///
///     missing   SEEDING  TRANSPLANTING  IRRIGATION  LAB_TEST  GRAZING
///     invented  OTHER
///
/// `LogEntry.type` is non-optional, so ONE entry of an unknown type fails the
/// whole list decode — every entry disappears, not just that one. It had not
/// bitten yet only because the live tenant holds nothing but INPUT_APPLICATION
/// (9) and ACTIVITY (2); the first Сеитба or Напояване entry would have done
/// it. `OTHER` was the write-side twin: creating with it would have been
/// rejected by the server's enum.
enum LogEntryType: String, Codable, CaseIterable, Identifiable, Sendable {
    case activity = "ACTIVITY"
    case observation = "OBSERVATION"
    case inputApplication = "INPUT_APPLICATION"
    case seeding = "SEEDING"
    case transplanting = "TRANSPLANTING"
    case harvest = "HARVEST"
    case irrigation = "IRRIGATION"
    case maintenance = "MAINTENANCE"
    case labTest = "LAB_TEST"
    case grazing = "GRAZING"

    var id: String { rawValue }

    /// Taken VERBATIM from the web app's `messages/bg.json`
    /// `journalEnums.logType.*`, so both clients name the same thing the same
    /// way to the same operator. (`INPUT_APPLICATION` read "Влагане" here and
    /// "Внасяне на препарат" there — the web app's wording wins.)
    var label: String {
        switch self {
        case .activity: "Дейност"
        case .observation: "Наблюдение"
        case .inputApplication: "Внасяне на препарат"
        case .seeding: "Сеитба"
        case .transplanting: "Разсаждане"
        case .harvest: "Прибиране на реколтата"
        case .irrigation: "Напояване"
        case .maintenance: "Поддръжка"
        case .labTest: "Лабораторен анализ"
        case .grazing: "Паша"
        }
    }
}

enum LogEntryStatus: String, Codable, Sendable {
    case planned = "PLANNED"
    case done = "DONE"

    var label: String { self == .planned ? "Планирано" : "Готово" }
}

struct LogEntry: Codable, Identifiable, Sendable {
    let id: String
    var type: LogEntryType
    var status: LogEntryStatus
    var title: String
    var notes: String?
    var occurredAt: Date
    /// Optimistic-concurrency counter. The server bumps it on every write and
    /// a replayed edit must send the version it SAW — see README, "Writes".
    var version: Int?
}

struct CreateLogEntry: Encodable, Sendable {
    var type: LogEntryType
    var status: LogEntryStatus = .done
    var title: String
    var notes: String?
    var occurredAt: Date?
}

/// The list endpoint's paginated envelope.
///
/// The key is `rows`, NOT `items`. The use-case returns `{ items, pageInfo }`
/// but the ROUTE re-shapes it to `{ rows, nextCursor }` before responding, and
/// the wire is what a client sees. Guessing `items` from the use-case name
/// produces a decode failure and an ever-empty list.
struct JournalPage: Decodable, Sendable {
    let rows: [LogEntry]
    let nextCursor: String?
}
