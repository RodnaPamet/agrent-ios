import Foundation

/// The server calls this a Task. Swift already has `Task`, and shadowing the
/// concurrency type in a codebase built on actors and `async` would be a
/// daily cost for a name nobody sees. The server's own enums are all
/// `WorkItem*` — `WorkItemType`, `WorkItemStatus`, `WorkItemSeverity` — so
/// this is the server's other name for the same thing, not one invented here.
///
/// Field list taken from the wire, not the Prisma model. Those differ: the
/// journal's use case returns `{items, pageInfo}` and its ROUTE reshapes to
/// `{rows, nextCursor}` before responding. For a single work item the route
/// does not reshape, but the rule stands — read the route.
///
/// NO NUMBERS ON THIS TYPE. Not a single Decimal or numeric column, which is
/// worth stating because the codebase has both conventions live at once:
/// `Parcel.areaHa` is a number and `ExchangeListing.quantityTonnes` is a
/// decimal-as-string, both verified. There was no third guess to make here.
struct WorkItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let tenantId: String
    let type: WorkItemType
    let title: String

    /// ENCRYPTED at rest and sanitised on write, plain text on the wire.
    /// Send plain text, expect plain text — unlike journal `notes`, which is
    /// rich-text HTML and needs `RichText`.
    let description: String?

    let severity: WorkItemSeverity
    let priority: WorkItemPriority
    let status: WorkItemStatus
    let source: WorkItemSource?
    let key: String?

    /// Encrypted at rest, plain text on the wire. See `description`.
    let resolution: String?

    let dueAt: Date?
    let completedAt: Date?
    let createdByUserId: String
    let assigneeUserId: String?
    let reviewerUserId: String?
    let operationType: FieldOperationType?
    let applicationTechnique: String?

    /// The dedupe key the server stores for a create. Present on the way
    /// back; the app sends it as `Idempotency-Key`, not in the body.
    let clientMutationId: String?

    /// `metadataJson` is NOT modelled, deliberately, and this is the same
    /// call as `Parcel.properties`. Arbitrary keys with mixed value types
    /// mean even `[String: String]` fails the WHOLE payload on one Int — so
    /// modelling it badly costs the entire list, and modelling it properly
    /// costs an AnyCodable nothing on screen would read.
    var isOverdue: Bool {
        guard let dueAt, completedAt == nil else { return false }
        return dueAt < Date()
    }
}

// MARK: - Enums
//
// Every case below was COUNTED against the server's enum definitions, not
// recalled. `LogEntryType` shipped six cases against ten and survived only
// because the live tenant happened to hold two of them; the first `Сеитба`
// entry would have failed the whole list decode, every row vanishing rather
// than the one.
//
// All of them adopt `LenientDecodable` anyway. Counting correctly today does
// not stop the server adding a case tomorrow, and the cost of being wrong is
// asymmetric: a vague label on one field, versus an empty screen.
//
// Bulgarian labels are taken VERBATIM from the web app's `messages/bg.json`
// `taskEnums.*`, so both clients name the same thing the same way to the same
// operator.

enum WorkItemType: String, LenientDecodable, Sendable {
    case improvement = "IMPROVEMENT"
    case task = "TASK"
    case fieldOperation = "FIELD_OPERATION"
    case farmTask = "FARM_TASK"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .task: "Задача"
        case .farmTask: "Земеделска задача"
        case .fieldOperation: "Земеделска операция"
        case .improvement: "Подобрение"
        case .unknown: "Друго"
        }
    }
}

enum WorkItemSeverity: String, LenientDecodable, Sendable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .info: "Информация"
        case .low: "Ниска"
        case .medium: "Средна"
        case .high: "Висока"
        case .critical: "Критична"
        case .unknown: "—"
        }
    }
}

enum WorkItemPriority: String, LenientDecodable, Sendable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .p0: "Спешен"
        case .p1: "Висок"
        case .p2: "Нормален"
        case .p3: "Нисък"
        case .unknown: "—"
        }
    }
}

/// Eight, and the wording is `taskEnums.status` — NOT `agStatus.operation`.
///
/// The server carries TWO Bulgarian vocabularies for these same codes. The
/// operations view says RESOLVED is "Разрешена", TRIAGED is "Приоритизирана"
/// and CANCELED is "Отменена"; the task vocabulary says "Готова",
/// "Планирана" and "Отказана".
///
/// A phone showing "Готова" where the web shows "Разрешена" for the same row
/// is worse than either word being wrong on its own, because the operator
/// cannot tell whether they are looking at the same record. This is the task
/// list, so it takes the task vocabulary. If a FIELD_OPERATION screen later
/// wants the operations wording that is a deliberate choice for that screen,
/// not a default that leaked.
enum WorkItemStatus: String, LenientDecodable, Sendable {
    case open = "OPEN"
    case triaged = "TRIAGED"
    case inProgress = "IN_PROGRESS"
    case blocked = "BLOCKED"
    case pendingReview = "PENDING_REVIEW"
    case resolved = "RESOLVED"
    case closed = "CLOSED"
    case canceled = "CANCELED"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .open: "Отворена"
        case .triaged: "Планирана"
        case .inProgress: "В процес"
        case .blocked: "Блокирана"
        case .pendingReview: "Очаква преглед"
        case .resolved: "Готова"
        case .closed: "Затворена"
        case .canceled: "Отказана"
        case .unknown: "—"
        }
    }

    /// Nothing more is expected to happen to it.
    var isFinished: Bool {
        switch self {
        case .resolved, .closed, .canceled: true
        case .open, .triaged, .inProgress, .blocked, .pendingReview, .unknown: false
        }
    }
}

enum WorkItemSource: String, LenientDecodable, Sendable {
    case manual = "MANUAL"
    case template = "TEMPLATE"
    case policyReview = "POLICY_REVIEW"
    case audit = "AUDIT"
    case integration = "INTEGRATION"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }
}

enum FieldOperationType: String, LenientDecodable, Sendable {
    case spray = "SPRAY"
    case fertilize = "FERTILIZE"
    case seed = "SEED"
    case other = "OTHER"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .spray: "Пръскане"
        case .fertilize: "Торене"
        case .seed: "Сеитба"
        case .other: "Друга"
        case .unknown: "—"
        }
    }
}
