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
/// the lines section needs, the lines, and — since the task map
/// (agrent-ios#177) — the location and its parcels.
///
/// `progress` is not decoded. The spec says it is derived from `lines` (DONE
/// or SKIPPED over all), and the screen derives its own from the lines PLUS
/// the marks still on the phone, as the web's offline panel does — so a
/// server count would be a second number for one fact.
struct FieldOperationDetail: Decodable, Equatable, Sendable {
    let task: Job
    let lines: [OperationLine]

    /// The job's location: «Resolved through the Task↔Location TaskLink» and
    /// NULL when the job has none, which the spec calls «a signal, not just an
    /// absence» — a partially committed create leaves exactly that.
    let location: Place?

    /// EVERY parcel of that location, with geometry — the map's context, not
    /// the job's parcels (those are the lines'). Empty when `location` is null.
    ///
    /// The spec types the items as an open object; they come from
    /// `ParcelRepository.listForLocation`, the call behind
    /// `GET /locations/{id}/parcels`, so they decode as that route's `Parcel`
    /// (documenting them is asked of agri-saas, agrent-ios#177).
    ///
    /// LOSSY, PER PARCEL, AND NEVER AT THE LINES' EXPENSE. The lines are the
    /// work; the map is context. A parcel that will not decode is dropped on
    /// its own, and a `parcels` or `location` that will not decode at all
    /// leaves the job with no map — not with no lines.
    let parcels: [Parcel]

    struct Place: Decodable, Equatable, Sendable {
        let id: String
        let name: String
    }

    init(task: Job, lines: [OperationLine], location: Place? = nil, parcels: [Parcel] = []) {
        self.task = task
        self.lines = lines
        self.location = location
        self.parcels = parcels
    }

    private enum CodingKeys: String, CodingKey { case task, lines, location, parcels }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(Job.self, forKey: .task)
        lines = try container.decode([OperationLine].self, forKey: .lines)
        location = (try? container.decodeIfPresent(Place.self, forKey: .location)) ?? nil
        parcels = ((try? container.decodeIfPresent([Lossy<Parcel>].self, forKey: .parcels)) ?? nil)?
            .compactMap(\.value) ?? []
    }

    /// One array element that may not decode, without failing the array.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

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
            lines: lines.map { $0.id == lineID ? $0.with(status: status, version: version) : $0 },
            location: location,
            parcels: parcels
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
    /// ── REQUIRED, as the contract now has it ──
    ///
    /// It was optional while the spec's `OperationParcel` did not list it and
    /// it arrived only by `.passthrough()`: a line without one was shown and
    /// not markable, because the route reads an absent `If-Match` as "no
    /// precondition" — the silent last-write-wins #138 exists to stop.
    /// agri-saas#1381 made it a required integer in the spec, and the column
    /// was always `Int @default(0)`, never null. So every line has one, every
    /// line can be guarded, and the not-markable branch is gone (#173). A line
    /// without one is a broken contract, and failing the decode says so.
    let version: Int

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
