import Foundation

/// A row of the task LIST, which is a projection and not a whole task.
///
/// MEASURED against production on 2026-09-22, because the field list I was
/// given was the model's and the wire's is smaller. The list route returns
/// exactly eleven keys:
///
///     id · key · title · type · status · severity · dueAt
///     assignee · assigneeUserId · createdAt · updatedAt
///
/// **`priority` is NOT among them.** Nor `tenantId`, `description`,
/// `source`, `resolution`, `completedAt`, `createdByUserId`,
/// `reviewerUserId`, `operationType` or `applicationTechnique`. A model built
/// from the full field list fails the whole list decode on `tenantId` — which
/// is precisely what it did, on the first run, on the device.
///
/// This is the "read the ROUTE, not the model" rule biting the person who
/// wrote it down two files ago. The rule was right and I applied it to the
/// envelope, where the previous bug had been, and not to the element. A
/// lesson learned in one position does not transfer itself to another.
///
/// The keys were taken as a UNION across all eight rows, not from the first:
/// `dueAt` and `assignee` are null on some rows, and reading one row would
/// have missed whichever keys that row happened not to carry.
struct WorkItemSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String

    /// The human-facing reference, e.g. the thing an operator reads out on
    /// the phone. Non-null on every row measured.
    let key: String

    let title: String
    let type: WorkItemType
    let status: WorkItemStatus
    let severity: WorkItemSeverity

    /// Null on all eight production rows today, so the overdue and
    /// due-date paths below are MODELLED, NOT VERIFIED. First task with a
    /// deadline is the first real test of them.
    let dueAt: Date?

    let assignee: Assignee?
    let assigneeUserId: String?
    let createdAt: Date
    let updatedAt: Date

    /// A person, which makes this the first PERSONAL DATA the app models.
    ///
    /// `name` and `email` are a third party's details. Two rules follow and
    /// neither is optional:
    ///
    ///   - They may be DISPLAYED — that is what the field is for.
    ///   - They must never reach a log, a query parameter or a cache key.
    ///     CFNetwork writes full request URLs to the unified log from
    ///     Apple's own subsystems and the app cannot suppress it, so a
    ///     filter-by-assignee must use a header or a body. See ROADMAP,
    ///     Phase 0.
    struct Assignee: Decodable, Equatable, Sendable {
        let id: String
        let name: String?
        let email: String?

        /// What to show. Falls back to the email only if there is no name,
        /// and to nothing at all if there is neither — an empty chip is
        /// better than the word "Unknown" in English on a Bulgarian screen.
        var displayName: String? {
            if let name, !name.isEmpty { return name }
            if let email, !email.isEmpty { return email }
            return nil
        }
    }

    var isOverdue: Bool {
        guard let dueAt else { return false }
        return dueAt < Date() && !status.isFinished
    }
}

/// A whole task, as the DETAIL route returns it.
///
/// ── NOT VERIFIED AGAINST A RESPONSE ──
///
/// Every field here comes from the server's own field list, which is a good
/// source and is not the same thing as having decoded one. The list route
/// turned out to send eleven of these nineteen, and that difference was only
/// found by running it. Treat this as modelled until a detail screen exists
/// and has loaded a real task; the first one to do so is the test.
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
