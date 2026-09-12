import Foundation

/// Mirrors prisma/schema/journal.prisma `LogEntryType`.
enum LogEntryType: String, Codable, CaseIterable, Identifiable, Sendable {
    case activity = "ACTIVITY"
    case observation = "OBSERVATION"
    case inputApplication = "INPUT_APPLICATION"
    case harvest = "HARVEST"
    case maintenance = "MAINTENANCE"
    case other = "OTHER"

    var id: String { rawValue }

    /// Bulgarian first — the operators using this are Bulgarian, and the web
    /// app's own journalEnums.logType.* reads this way.
    var label: String {
        switch self {
        case .activity: "Дейност"
        case .observation: "Наблюдение"
        case .inputApplication: "Влагане"
        case .harvest: "Прибиране на реколтата"
        case .maintenance: "Поддръжка"
        case .other: "Друго"
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

/// The list endpoint is paginated; the slice reads the first page only.
struct JournalPage: Decodable, Sendable {
    let items: [LogEntry]
    let nextCursor: String?
}
