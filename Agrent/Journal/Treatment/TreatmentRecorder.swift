import Foundation

/// What «Ново мероприятие» saves: one treatment, done, on the chosen parcels.
///
/// Built only from a draft with no problems and at least one parcel, so a
/// record that exists is one the server can be asked to keep.
struct TreatmentRecord: Equatable, Sendable {
    struct NewProduct: Equatable, Sendable {
        let pppRegistrationNo: String
        let quarantineDays: Int
    }

    let kind: TreatmentDraft.Kind
    /// A calendar DAY: the live recorder sends it as one (`BgDate.isoDay`),
    /// never as an instant a time zone could move to the day before.
    let date: Date
    /// The STORED name on a catalogue match, so the server meets exactly the
    /// row matched here; otherwise the typed one, trimmed.
    let productName: String
    /// Only for a plant protection product the farm does not have yet.
    let newProduct: NewProduct?
    /// The period this entry was recorded with — prefilled from the product
    /// and editable, as PRZ has it. nil for fertilising.
    let quarantineDays: Int?
    let pest: String?
    let dose: Decimal
    let doseUnitID: String
    /// The slug, never the label: it prints raw onto the ДНЕВНИК.
    let technique: ApplicationTechnique?
    let parcelIDs: [String]

    /// nil while the draft has a problem or no parcel is chosen.
    static func make(_ draft: TreatmentDraft, catalogue: [InputItem]?,
                     fields: [TreatmentPlace.Field], now: Date = Date()) -> TreatmentRecord? {
        guard draft.problems(catalogue: catalogue, now: now).isEmpty, !fields.isEmpty,
              let dose = draft.dose, let unit = draft.doseUnit else { return nil }
        let typed = draft.typed(in: catalogue)
        let name: String
        switch typed {
        case .existing(let item): name = item.name
        case .new: name = TypedProduct.cleaned(draft.productText)
        case .empty, .wrongKind, .sample: return nil
        }
        let spraying = draft.kind == .spray
        let registration = draft.registrationText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TreatmentRecord(
            kind: draft.kind,
            date: draft.date,
            productName: name,
            newProduct: spraying && typed == .new
                ? NewProduct(pppRegistrationNo: registration, quarantineDays: draft.quarantineDays ?? 0)
                : nil,
            quarantineDays: spraying ? draft.quarantineDays : nil,
            pest: spraying ? draft.pestText.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            dose: dose,
            doseUnitID: unit.id,
            technique: spraying ? draft.technique : nil,
            parcelIDs: fields.map(\.id)
        )
    }
}

/// Which `Idempotency-Key` a save goes out under (agrent-ios#293).
///
/// The same key for the same ENTRY across retries, so a retry after a lost
/// answer cannot record it twice; a new one once the person has changed what
/// they entered, because a corrected entry is a different entry. Compared on
/// what was ENTERED — the draft and the set of parcels — never on the
/// resolved record: that changes when the catalogue loads between two
/// attempts (a typed name becomes the stored one), and a key minted for an
/// entry nobody touched would let a timed-out save land twice.
///
/// Whether a reused key with a DIFFERENT body is refused or replayed is the
/// server's to say (agri-saas #1740).
struct TreatmentAttempt: Equatable, Sendable {
    private(set) var key = UUID().uuidString
    private var last: Entered?

    private struct Entered: Equatable, Sendable {
        let draft: TreatmentDraft
        let parcels: Set<String>
    }

    mutating func key(for draft: TreatmentDraft, parcels: [String]) -> String {
        let entered = Entered(draft: draft, parcels: Set(parcels))
        if let last, last != entered { key = UUID().uuidString }
        last = entered
        return key
    }
}

/// Where a treatment is saved and its ДНЕВНИК pages come from.
///
/// ── No live one yet ──
///
/// Both need routes agri-saas does not have (#1740): recording a DONE
/// treatment on parcels from several blocks in one idempotent request, and
/// the ДНЕВНИК limited to one entry. The screens are built against this, and
/// «Нов запис» opens them once the routes are in the spec — until then the
/// journal keeps its old form, so nothing on the phone writes to a route
/// that does not exist.
protocol TreatmentRecorder: Sendable {
    /// Saves the record and returns the entry's id. The key is minted once
    /// per entry and reused on a retry, so a retry cannot save it twice.
    func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> String
    /// The ДНЕВНИК pages for one entry, as a local PDF for Quick Look.
    func document(forEntry id: String) async throws -> URL
}
