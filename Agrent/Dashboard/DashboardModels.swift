import Foundation

/// The four dashboard routes, modelled from `openapi.json` on agri-saas main
/// (`fbb25ab29`, fetched 2026-09-25).
///
/// ── Two ways this spec says "nullable", and I misread one of them ──
///
/// Worth recording, because it is the mistake a reader of this file is most
/// likely to repeat. This spec expresses a nullable object BOTH ways:
///
///     LocationListItem.owner   allOf: [ {$ref: UserRef}, {type: ["object","null"]} ]
///     FieldBriefingPayload.briefing        {$ref: FieldBriefing}
///         …where FieldBriefing itself is  {type: ["object","null"]}
///
/// I read the second as non-nullable and reported it to the server session as
/// a contract defect. It is not one. In OpenAPI 3.1 a `$ref` to a schema whose
/// own `type` admits null admits null, and the difference between the two
/// idioms is whether the target type is REUSED: `UserRef` appears in five
/// payloads and cannot bake a null into itself, while `FieldBriefing` and
/// `AgDashboardAchievements` are single-use and can.
///
/// So the rule for reading this file's source is: check the TARGET schema's
/// own `type`, not only the reference site. Two fields here are optional for
/// exactly that reason and would otherwise have been declared non-optional —
/// which, inside an envelope, is the defect that has cost this repo a whole
/// screen four times.

// MARK: - GET /dashboard/ag

/// The farm's own dashboard: what was logged, what is running out, what is
/// assigned, and what the farm has achieved.
struct AgDashboard: Decodable, Equatable, Sendable {
    /// ABSENCE IS THE SIGNAL. A disabled module is simply not in this array.
    ///
    /// The array is always present and always an array, so a gated tenant
    /// gets `[]` sections rather than missing keys — which means "empty
    /// because gated" and "empty because nothing recorded" are NOT
    /// distinguishable from the section arrays alone. This list is the only
    /// thing that tells them apart, and a screen that says «Няма записи» for a
    /// module the farm never bought is telling a farmer his data is missing.
    ///
    /// ── The names are not in the spec ──
    ///
    /// `items` is a bare `{type: string}` with no enum, so the vocabulary this
    /// is compared against appears nowhere a client can read. The mechanism is
    /// documented and the values are not — the same gap as the weed catalogue,
    /// and raised with the server session as such.
    ///
    /// So `isEnabled` matches case-insensitively and NOTHING here hardcodes a
    /// list of modules. An unrecognised name is simply a module this build
    /// does not ask about, which costs nothing; guessing the spelling of one
    /// it does ask about would silently gate a section off.
    let enabledModules: [String]

    let recentJournal: [JournalItem]
    let lowStock: [LowStockItem]
    let myTasks: [TaskItem]

    /// NULLABLE — `AgDashboardAchievements` is `{type: ["object","null"]}`,
    /// even though `achievements` is in `required`. Required means the KEY is
    /// present, not that the value is an object.
    let achievements: Achievements?

    /// Whether the farm has this module, by the server's own list.
    ///
    /// Case-insensitive because the spelling is unverifiable from here; see
    /// `enabledModules`.
    func isEnabled(_ module: String) -> Bool {
        enabledModules.contains { $0.caseInsensitiveCompare(module) == .orderedSame }
    }

    struct JournalItem: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        /// The existing `LogEntryType`, not a second copy of that vocabulary.
        /// It is `LenientDecodable`, so a kind this build has not heard of
        /// becomes `.unknown` rather than failing the dashboard.
        let type: LogEntryType
        let title: String

        /// Nullable, and with no `format` declared — so parsed leniently
        /// rather than decoded, for the reason in `BgDate.parseInstantOrDay`.
        let occurredAtRaw: String?
        var occurredAt: Date? { BgDate.parseInstantOrDay(occurredAtRaw) }

        enum CodingKeys: String, CodingKey {
            case id, type, title
            case occurredAtRaw = "occurredAt"
        }
    }

    struct LowStockItem: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String

        /// `type: number` on the wire. `WireDecimal` takes the number branch
        /// straight to `Decimal` without passing through `Double` — this is a
        /// quantity a farmer reorders against, and binary floating point is
        /// what that type exists to keep out of it.
        let quantityOnHand: WireDecimal

        /// Through `.recorded`, because a unit symbol read off an optional
        /// relation is exactly the `?? ''` collapse that shipped twice here as
        /// a trailing space. Required and `type: string` is true of an empty
        /// string too.
        var unitSymbol: String? { unitSymbolRaw.recorded }
        private let unitSymbolRaw: String

        enum CodingKeys: String, CodingKey {
            case id, name, quantityOnHand
            case unitSymbolRaw = "unitSymbol"
        }

        /// « 12,5 л », or the number alone when no unit was recorded. Never a
        /// placeholder and never a dangling separator.
        var quantityText: String {
            let fraction = quantityOnHand.raw.split(separator: ".").dropFirst().first?.count ?? 0
            let number = quantityOnHand.text(scale: fraction)
            guard let unitSymbol else { return number }
            return "\(number) \(unitSymbol)"
        }
    }

    struct TaskItem: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        /// The existing `WorkItemStatus`, lenient, so a new status does not
        /// fail the dashboard.
        let status: WorkItemStatus

        let dueAtRaw: String?
        var dueAt: Date? { BgDate.parseInstantOrDay(dueAtRaw) }

        enum CodingKeys: String, CodingKey {
            case id, title, status
            case dueAtRaw = "dueAt"
        }
    }

    /// Milestones and a streak.
    ///
    /// Every milestone arrives with `earned` false rather than being omitted,
    /// which the server states explicitly — so a client renders the full set
    /// and never has to know the list. That is the opposite of
    /// `enabledModules`, in the same payload, and the contrast is worth
    /// noticing: here absence is impossible, there absence is the signal.
    struct Achievements: Decodable, Equatable, Sendable {
        let milestones: [Milestone]
        let streak: Streak

        struct Streak: Decodable, Equatable, Sendable {
            let current: Int
            let best: Int
        }

        struct Milestone: Decodable, Equatable, Identifiable, Sendable {
            let key: Key
            let earned: Bool

            /// Null EXACTLY when `earned` is false — the server says so, and
            /// `wasEarned` prefers the flag over the date for the same reason
            /// the exchange tombstone reads `deleted` rather than `body ==
            /// nil`: the flag is the contract and the null is a consequence.
            let earnedAtRaw: String?
            var earnedAt: Date? { BgDate.parseInstantOrDay(earnedAtRaw) }

            var id: String { key.rawValue }

            enum CodingKeys: String, CodingKey {
                case key, earned
                case earnedAtRaw = "earnedAt"
            }

            /// A milestone's identity, and THIS ONE THE SPEC PINS.
            ///
            /// Eight values, in an `enum` on the schema — unlike the weed
            /// catalogue, which is named in a description and appears in no
            /// machine-readable form. So this list is checkable and the weed
            /// list is not, which is why one gets a sentinel for safety and
            /// the other gets a sentinel plus a standing question.
            enum Key: String, LenientDecodable, Sendable {
                case framework100 = "framework-100"
                case evidenceAllCurrent = "evidence-all-current"
                case auditPackComplete = "audit-pack-complete"
                case firstPracticeMapped = "first-practice-mapped"
                case firstFieldMapped = "first-field-mapped"
                case sprayJobComplete = "spray-job-complete"
                case firstHarvest = "first-harvest"
                case seasonClosed = "season-closed"
                case unknown = "UNKNOWN"

                static var unknownCase: Self { .unknown }

                /// MINE, not the server's — the spec pins the keys and says
                /// nothing about what to call them. Lower stakes than the weed
                /// names, which a farmer acts on, but still written here
                /// rather than received.
                var label: String {
                    switch self {
                    case .framework100: "Рамката е попълнена"
                    case .evidenceAllCurrent: "Всички доказателства са актуални"
                    case .auditPackComplete: "Одитният пакет е готов"
                    case .firstPracticeMapped: "Първа описана практика"
                    case .firstFieldMapped: "Първо картирано поле"
                    case .sprayJobComplete: "Първо завършено пръскане"
                    case .firstHarvest: "Първа реколта"
                    case .seasonClosed: "Приключен сезон"
                    // A milestone added server-side. Named rather than hidden:
                    // a farmer who earned something should not see a gap.
                    case .unknown: "Ново постижение"
                    }
                }
            }
        }
    }
}
