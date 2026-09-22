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
struct WorkItemSummary: Decodable, Identifiable, Equatable, Hashable, Sendable {
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
    struct Assignee: Decodable, Equatable, Hashable, Sendable {
        let id: String
        let name: String?
        let email: String?

        /// What to show. Falls back to the email only if there is no name,
        /// and to nothing at all if there is neither — an empty space is
        /// better than the word "Unknown" in English on a Bulgarian screen.
        var displayName: String? {
            Self.readable(name) ?? Self.readable(email)
        }

        /// Reject anything that is not a name a person could read.
        ///
        /// MEASURED on the device, 2026-09-22: the task detail route
        /// returned a `createdBy.name` of
        ///
        ///     v1:FTDt/A1v/6KngIxn762VOuI9kQdrKrz69Se6XnFAUBVSb0L/Nm8r
        ///
        /// which is an encryption envelope, not a name. The field is
        /// encrypted at rest and that response did not decrypt it. The
        /// screen rendered it verbatim under "Създадена от", so an operator
        /// was shown 54 characters of base64 where a colleague's name
        /// belongs.
        ///
        /// Raised with the server, and it is theirs to fix. This is the
        /// client half, and it belongs here regardless: a ciphertext is
        /// never something to show a person, whatever the reason it
        /// arrived. Showing nothing loses one fact; showing the blob makes
        /// the screen look broken and teaches the operator to distrust it.
        ///
        /// Matched on the versioned envelope prefix — `v` digits `:` — not
        /// on "looks like base64", which would eventually eat a real value.
        /// A colon cannot appear in a person's name in any case this app
        /// serves.
        private static func readable(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !isCipherEnvelope(trimmed) else { return nil }
            return trimmed
        }

        static func isCipherEnvelope(_ text: String) -> Bool {
            guard let colon = text.firstIndex(of: ":"), colon > text.startIndex else {
                return false
            }
            let tag = text[text.startIndex..<colon]
            guard tag.first == "v" else { return false }
            let digits = tag.dropFirst()
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
    }

    var isOverdue: Bool {
        guard let dueAt else { return false }
        return dueAt < Date() && !status.isFinished
    }
}

/// A whole task, as the DETAIL route returns it.
///
/// VERIFIED against production on 2026-09-22 — decoded from a real response
/// before this screen was written, rather than after it failed. The list
/// route's projection was found the other way round and cost a screen.
///
/// The detail route sends THIRTY-THREE keys, not the nineteen of the model:
/// beyond the scalars there are `assignee`, `createdBy` and `reviewer` as
/// objects, `comments`, `links` and `watchers` as arrays, a `_count`, an
/// `sla`, `createdAt`/`updatedAt`, and the soft-delete and retention
/// columns. The extra keys are ignored by Codable, so the model would have
/// worked — but it would have quietly left the useful half on the wire, and
/// "it decoded" is not the same as "we read what was there".
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

    let createdAt: Date
    let updatedAt: Date

    /// Three people, all optional, all personal data. Same rule as
    /// `WorkItemSummary.Assignee`: displayable, never logged, never in a
    /// query parameter or a cache key.
    let assignee: WorkItemSummary.Assignee?
    let createdBy: WorkItemSummary.Assignee?
    let reviewer: WorkItemSummary.Assignee?

    let sla: SLA?

    /// How many of each related thing exist, WITHOUT the things themselves.
    ///
    /// The detail payload also carries `comments`, `links` and `watchers` as
    /// arrays, and they are deliberately not modelled: all three were empty
    /// on the task measured, so their element shapes are unknown, and
    /// guessing an element shape is what cost the list screen its first run.
    /// A count is honest and enough to say "3 коментара" — the elements can
    /// be modelled the day a screen reads them, against a response that has
    /// some.
    let counts: Counts?

    struct SLA: Decodable, Equatable, Sendable {
        /// NOT displayed, deliberately. It is a server-authored string and
        /// nothing establishes that it is Bulgarian — and this app's one
        /// rule about English is that it reaches the operator only through
        /// an error path we cannot yet translate, never through a label we
        /// chose to render. The breach flags below carry the meaning in
        /// words this app owns.
        let label: String?
        let triageBreach: Bool?
        let resolveBreach: Bool?

        var isBreached: Bool { triageBreach == true || resolveBreach == true }
    }

    struct Counts: Decodable, Equatable, Sendable {
        let comments: Int?
        let evidence: Int?
        let links: Int?
        let watchers: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case id, tenantId, type, title, description, severity, priority
        case status, source, key, resolution, dueAt, completedAt
        case createdByUserId, assigneeUserId, reviewerUserId
        case operationType, applicationTechnique, clientMutationId
        case createdAt, updatedAt, assignee, createdBy, reviewer, sla
        /// The wire name is `_count`, which is not a legal Swift property
        /// name and would be a poor one anyway.
        case counts = "_count"
    }

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

    /// Where this status may legally go, via `POST /tasks/:id/status`.
    ///
    /// Taken from the server's `WORK_ITEM_TRANSITIONS`, with ONE removal:
    /// `PENDING_REVIEW` is reachable in the server's table but is not
    /// accepted by this route's schema — it is the field-operation review
    /// gate and is reached by that flow. Sending it gets a zod 400. So it is
    /// absent here rather than offered and refused.
    ///
    /// Offering only legal moves rather than showing a button that fails is
    /// the point: an operator who taps "Затворена" on a CANCELED task and
    /// gets an error has been told the app is broken, when in fact they
    /// asked for something that was never possible.
    ///
    /// `CLOSED` and `CANCELED` are SINKS. Nothing leaves them, by design,
    /// and a task that reaches one is finished with.
    /// ── RESOLVED IS NOT OFFERED AS A DESTINATION (owner, 2026-09-22) ──
    ///
    /// The server permits it from four states and this app offered all
    /// four. The WEB retired it: there an active task closes in one step,
    /// and RESOLVED survives only as an intermediate on rows that already
    /// hold it.
    ///
    /// Two clients disagreeing about a workflow is worse than either
    /// workflow. An operator who marks a task Готова on the phone and
    /// finds their colleague cannot see that step on the laptop has been
    /// given a state the rest of the farm does not use.
    ///
    /// Transitions OUT of `.resolved` are kept, and that is not an
    /// inconsistency: rows already sit in that state, and a task that
    /// cannot be closed because the app declines to name where it is
    /// would be stranded by our own tidiness.
    var allowedNext: [WorkItemStatus] {
        switch self {
        case .open:          [.triaged, .inProgress, .blocked, .closed, .canceled]
        case .triaged:       [.inProgress, .blocked, .closed, .canceled]
        case .inProgress:    [.triaged, .blocked, .closed, .canceled]
        case .blocked:       [.inProgress, .triaged, .closed, .canceled]
        case .pendingReview: [.inProgress, .closed, .canceled]
        // Already there. Kept so such a task can still be moved on.
        case .resolved:      [.inProgress, .closed]
        // Sinks, and an unknown status we cannot reason about at all.
        case .closed, .canceled, .unknown: []
        }
    }

    /// Moving to one of these requires a resolution — required, and
    /// non-empty AFTER the server sanitises it, so a resolution made only of
    /// markup is refused rather than stored as something that renders as
    /// nothing.
    var requiresResolution: Bool {
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
