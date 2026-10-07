import Foundation

/// One field operation as `GET /field-operations/{taskId}` returns it — the
/// job's prescription LINES, which is what an operator marks done
/// (agrent-ios#138, ported from the web's `FieldOperationPanel`).
///
/// ── Only what the screen reads ──
///
/// The route sends the whole job in one read: the Task row, every line, the
/// linked location with ALL of its parcels and their geometry (the web's map
/// backdrop), and a derived `progress`. This models the task's three fields
/// the lines section needs and the lines themselves. The map is not ported
/// (PARITY.md), so `location` and `parcels` stay on the wire — geometry is
/// the heaviest part of the payload and nothing here would draw it.
///
/// `progress` is not decoded either. The spec says it is derived from
/// `lines` (DONE or SKIPPED over all), and the screen derives its own from
/// the lines PLUS the marks still on the phone, as the web's offline panel
/// does — so a server count would be a second number for one fact.
struct FieldOperationDetail: Decodable, Equatable, Sendable {
    let task: Job
    let lines: [OperationLine]

    /// The job's own row, cut to what decides who may mark it.
    ///
    /// `assigneeUserId` is the half of the route's permission rule that
    /// belongs to the job — the assigned operator may mark without general
    /// write permission (`markOperationParcel`). Read from THIS payload
    /// rather than from the task detail beside it, so the lines and the
    /// assignee they are gated on come from the same moment.
    struct Job: Decodable, Equatable, Sendable {
        let id: String
        /// Not in the spec's `Task` schema, which allows extra keys; the
        /// route returns the raw row, and the web reads it. Optional, so a
        /// server that drops it costs a label and never the screen.
        let key: String?
        let assigneeUserId: String?
        let status: WorkItemStatus
    }

    /// The same job with one line set to `status` — and to `version`, when
    /// the server reported the line's new one.
    ///
    /// For the moment between a landed mark and the reload behind it: the
    /// row agrees with what the server just accepted instead of showing the
    /// pre-mark copy until the network answers. Without a version the line
    /// is left exactly as it was — a status beside a stale version would let
    /// the next tap assert a precondition for a state the server never held.
    func applying(_ status: OperationLineStatus, version: Int?, toLine lineID: String) -> FieldOperationDetail {
        guard let version else { return self }
        return FieldOperationDetail(
            task: task,
            lines: lines.map { $0.id == lineID ? $0.with(status: status, version: version) : $0 }
        )
    }
}

/// One prescription line: one parcel, one product, one dose.
///
/// The spec's `OperationParcel`. Marking one DONE is a REGULATED WRITE: the
/// server deducts dose × area from the product's inventory lot and files an
/// INPUT_APPLICATION entry in the ДНЕВНИК (`markOperationParcel` →
/// `recordInputApplication`), and un-completing does not reverse either —
/// the ledger is append-only. Nothing in development, CI or A11yShots sends
/// one; the owner makes the first (ROADMAP, known-unverified).
struct OperationLine: Decodable, Identifiable, Equatable, Sendable {
    /// The LINE's id — `lineId` in the PATCH path. Not the parcel's id: one
    /// parcel can carry two lines (a fertiliser and a treatment).
    let id: String
    let status: OperationLineStatus

    /// THE OPTIMISTIC LOCK, read with the line (agri-saas route.ts:12, #138).
    ///
    /// Every mark sends it back as `If-Match`, and a mark queued offline
    /// stores the one it SAW and replays with it — so a stale replay earns a
    /// 409 instead of overwriting whatever a supervisor did meanwhile.
    ///
    /// ── OPTIONAL, though the column is `Int @default(0)` ──
    ///
    /// The spec's `OperationParcel` schema does not list `version` at all.
    /// The route returns the raw Prisma row and the schema allows extra keys,
    /// so it arrives today — but it arrives by `.passthrough()`, not by
    /// contract. Required here, a server that stopped sending it would fail
    /// the whole job, and every line with it.
    ///
    /// Optional is not the same as tolerated: a line without a version is
    /// SHOWN and NOT MARKABLE (`FieldOperationRules.isMarkable`). The route
    /// reads an absent `If-Match` as "no precondition" — a silent
    /// last-write-wins — which is the exact overwrite #138 exists to stop, so
    /// the app never sends a mark it cannot guard.
    let version: Int?

    /// `Decimal(14,4)` through Prisma's `toJSON` — a STRING on this route,
    /// which `WireDecimal` reads along with the number form.
    let doseValue: WireDecimal
    let product: Named
    let doseUnit: DoseUnit
    let parcel: ParcelRef
    let completedAt: Date?

    struct Named: Decodable, Equatable, Sendable {
        let id: String
        let name: String
    }

    /// `name` is what VoiceOver says («литра на декар»); `symbol` is what is
    /// printed (`л/дка`), which a screen reader spells out letter by letter.
    struct DoseUnit: Decodable, Equatable, Sendable {
        let id: String
        let symbol: String
        let name: String?
    }

    struct ParcelRef: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        /// Hectares, as a Decimal STRING here — unlike `/parcels`, where the
        /// repository hands back a number. Same column, two wire types; see
        /// `WireDecimal`.
        let areaHa: WireDecimal?
    }

    /// The decimal dose, in Bulgarian — «0,25». Up to the column's four
    /// places, trailing zeros dropped: the server's string has already lost
    /// them, and a rate is read as the farmer typed it, not padded.
    var doseText: String {
        doseValue.value.formatted(
            .number.precision(.fractionLength(0...4)).grouping(.automatic).locale(BgDate.locale)
        )
    }

    /// The parcel's area, in decares like every other area in the app.
    var area: Area? {
        guard let hectares = parcel.areaHa?.value else { return nil }
        return Area(hectares: NSDecimalNumber(decimal: hectares).doubleValue)
    }

    func with(status: OperationLineStatus, version: Int) -> OperationLine {
        OperationLine(id: id, status: status, version: version, doseValue: doseValue,
                      product: product, doseUnit: doseUnit, parcel: parcel, completedAt: completedAt)
    }
}

/// `PENDING | DONE | SKIPPED` — the request schema's enum, and the status a
/// line carries.
///
/// Labels VERBATIM from the web's `ag.status.operationParcel` in
/// `messages/bg.json`, so a line reads the same on the phone and on the
/// laptop. `Готово` is also the web's word for the button that sets it.
enum OperationLineStatus: String, LenientDecodable, Sendable {
    case pending = "PENDING"
    case done = "DONE"
    case skipped = "SKIPPED"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .pending: "Чакащо"
        case .done: "Готово"
        case .skipped: "Пропуснато"
        case .unknown: "—"
        }
    }

    /// Counted as progress — a skip is progress, by the spec's own
    /// definition of `progress.done`.
    var isComplete: Bool { self == .done || self == .skipped }
}
