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
/// a contract defect. It is not one: in OpenAPI 3.1 a `$ref` to a schema whose
/// own `type` admits null admits null.
///
/// THE RULE IS SIMPLY: CHECK THE TARGET SCHEMA'S OWN `type`, not only the
/// reference site. Two fields here are optional for exactly that reason and
/// would otherwise have been declared non-optional — which, inside an
/// envelope, is the defect that has cost this repo a whole screen four times.
///
/// ── And the tidy explanation I first wrote for it was also wrong ──
///
/// This comment claimed the two idioms differ by whether the target is REUSED:
/// that `UserRef` appears in several payloads and so cannot bake a null into
/// itself, while single-use types can. That reads well and it is false.
/// `BottomTabOrder` is `{type: ["array","null"]}` and is referenced at THREE
/// sites, so a reused target does bake null in. (`UserRef` is referenced ten
/// times, not five, which is what happens when a number is remembered rather
/// than counted.)
///
/// Twice in one paragraph, then: once reading a nullability, once inventing
/// the reason for it. The second is the worse habit, because a plausible
/// causal story is what a reader reasons FROM — somebody applying the reuse
/// rule would conclude a three-times-referenced schema cannot be nullable,
/// and be wrong about `BottomTabOrder` specifically.

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
        /// `LogEntryType`, and THIS IS AN ASSUMPTION RATHER THAN A CONTRACT.
        ///
        /// `AgDashboardJournalItem.type` is a bare `{type: string}` with no
        /// enum. The only place this spec enumerates journal kinds is
        /// `LogEntryCreateRequest.type`, on a different resource, so reusing
        /// that vocabulary here is inference — and reusing the app's existing
        /// enum is still better than a second copy of a guess.
        ///
        /// The risk is specific and quiet: because the enum is lenient, a
        /// WHOLE-VOCABULARY mismatch does not fail: every row decodes to
        /// `.unknown` and renders «—», on every row, forever, with nothing red
        /// anywhere. Leniency protects against one unknown value and hides a
        /// wrong assumption. Asked of the server session; until it answers,
        /// this is a question in a comment rather than a fact.
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

        /// NON-OPTIONAL, and this one was CHECKED rather than assumed.
        ///
        /// I had it going through `String.recorded`, on the reasoning that a
        /// unit symbol is exactly the kind of `?? ''` collapse that shipped
        /// twice here as a trailing space. Traced in agri-saas source at my
        /// request, it is not one:
        ///
        ///     inventory.prisma:77  unit Unit @relation(...)   // no `?`
        ///     ag-dashboard.ts:117  unitSymbol: l.unit.symbol  // no `?.`, no `?? ''`
        ///
        /// The relation is required, `listLots` types the symbol non-optional,
        /// and the projection reads it straight through. So the collapse list
        /// stays at four sites rather than five, and this is a plain string.
        ///
        /// `quantityText` still declines to print a separator for an empty one.
        /// Not defence against this field — defence costs nothing here and the
        /// asymmetry that justified keeping the parcel dose optional does not
        /// apply: a null dose THREW and cost a whole envelope, while a blank
        /// unit would only ever cost a trailing space.
        let unitSymbol: String

        /// « 12,5 л », or the number alone when no unit was recorded. Never a
        /// placeholder and never a dangling separator.
        ///
        /// ── THE SCALE IS TAKEN FROM THE VALUE, AGAINST `WireDecimal`'S RULE ──
        ///
        /// That type's own header says the opposite, under the heading "Scale
        /// comes from the COLUMN, not the value": `1.00` arrives as `1`, and
        /// rendering it through gives «1 лв» where the books say «1,00».
        ///
        /// It is right about money and this route publishes no scale at all.
        /// So the choice is between padding to a scale I would be inventing
        /// and showing the digits that arrived. For the parcel-history dose
        /// the server answered that question directly — `Decimal(14,4)`, and
        /// «do NOT pad to it», because `2,5000 л/дка` is worse than `2,5`. A
        /// reorder quantity is the same kind of number, so the same choice is
        /// made here.
        ///
        /// The cost is real and worth naming: a column of scale 3 sending
        /// 12.500, 12.000 and 12.125 renders «12,5», «12» and «12,125» in one
        /// list. Asked of the server session; if it names a scale AND says to
        /// pad, this becomes one line.
        var quantityText: String {
            let fraction = quantityOnHand.raw.split(separator: ".").dropFirst().first?.count ?? 0
            let number = quantityOnHand.text(scale: fraction)
            guard let unit = unitSymbol.recorded else { return number }
            return "\(number) \(unit)"
        }
    }

    struct TaskItem: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        /// `WorkItemStatus`, and the SAME ASSUMPTION as `JournalItem.type`,
        /// with a sharper reason to doubt it.
        ///
        /// `AgDashboardTaskItem.status` is a bare `{type: string}`. And
        /// `FarmTaskListItem.type` is documented «FARM_TASK or FIELD_OPERATION
        /// — the queue merges both», while a field operation's status
        /// vocabulary in this same spec is `[PENDING, DONE, SKIPPED]`, none of
        /// which `WorkItemStatus` contains. So if `myTasks` merges operations,
        /// those rows all decode to `.unknown` and show «—» silently.
        ///
        /// Asked. Not asserted.
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

            /// THE KEY AS SENT, kept because the enum throws it away.
            ///
            /// `LenientDecodable` maps anything unrecognised to `.unknown`, so
            /// `key.rawValue` is the literal "UNKNOWN" for every new milestone
            /// the server adds. `id` was built from that — which means two
            /// server-added milestones share one id, and a SwiftUI `ForEach`
            /// silently drops all but the first.
            ///
            /// So the comment promising that "a farmer who earned something
            /// should not see a gap" was producing exactly that gap as soon as
            /// there were two of them. The test only ever injected one unknown
            /// key, so the collision could not fail.
            let keyRaw: String

            /// Null EXACTLY when `earned` is false — the server says so, and
            /// `wasEarned` prefers the flag over the date for the same reason
            /// the exchange tombstone reads `deleted` rather than `body ==
            /// nil`: the flag is the contract and the null is a consequence.
            let earnedAtRaw: String?
            var earnedAt: Date? { BgDate.parseInstantOrDay(earnedAtRaw) }

            /// The WIRE key, never the enum's — see `keyRaw`.
            var id: String { keyRaw }

            /// What to call it: the mapped label for a key this build knows,
            /// and the server's own key for one it does not. Same shape as
            /// `WeedCatalogue.name(for:)` — an unmapped value is shown as
            /// stored rather than hidden or renamed.
            var label: String {
                key == .unknown ? keyRaw : key.label
            }

            /// AN EXPLICIT INIT, because `key` is read TWICE — once through
            /// `LenientDecodable` for the enum and once as the raw string. Two
            /// `CodingKeys` cases cannot share a raw value ("raw value for enum
            /// case is not unique"), and a keyed container is perfectly happy
            /// to be asked for the same key twice.
            ///
            /// Reading it through `Key.self` rather than matching by hand keeps
            /// the case-insensitivity that `LenientDecodable` gives every other
            /// enum in the app, instead of quietly introducing a stricter rule
            /// here.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                key = try c.decode(Key.self, forKey: .key)
                keyRaw = try c.decode(String.self, forKey: .key)
                earned = try c.decode(Bool.self, forKey: .earned)
                earnedAtRaw = try c.decodeIfPresent(String.self, forKey: .earnedAt)
            }

            private enum CodingKeys: String, CodingKey {
                case key, earned, earnedAt
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
