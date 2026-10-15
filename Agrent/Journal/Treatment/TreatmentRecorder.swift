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

/// Which `Idempotency-Key` a save goes out under, and what an earlier save
/// left behind (agrent-ios#293).
///
/// The same key for the same ENTRY across retries, so a retry after a lost
/// answer cannot record it twice; a new one once the person has changed what
/// they entered, because a corrected entry is a different entry. Compared on
/// what was ENTERED — the draft and the set of parcels — never on the
/// resolved record: that changes when the catalogue loads between two
/// attempts (a typed name becomes the stored one), and a key minted for an
/// entry nobody touched would let a timed-out save land twice.
///
/// The new key is not a nicety. The server REPLAYS a reused key whatever the
/// body (owner, 2026-10-14; agri-saas #1765): a corrected entry under the old
/// key is answered with the original and records nothing.
struct TreatmentAttempt: Equatable, Sendable {
    private(set) var key = UUID().uuidString
    private var last: Entered?
    /// The save that reached the server and was not answered with a success:
    /// what the server holds under its key is not known. Settled by `save`
    /// before an entry with a different key goes out.
    private(set) var unsettled: Sent?

    private struct Entered: Equatable, Sendable {
        let draft: TreatmentDraft
        let parcels: Set<String>
    }

    /// One entry as it went out — what the saved screen shows if this is the
    /// one the server kept.
    struct Sent: Equatable, Sendable {
        let key: String
        let record: TreatmentRecord
        let fields: [TreatmentPlace.Field]
        let cropLabel: String?
    }

    enum Outcome: Equatable, Sendable {
        /// Recorded. `changeLost` when what the server kept is an EARLIER
        /// save, without what the person changed after it.
        case saved(Sent, changeLost: Bool)
        /// Not answered, and kept on the phone to be sent under its own key
        /// (#324): with no signal, or — `afterUpdate` — from a build the
        /// server has retired, for the updated app to send.
        case queued(Sent, afterUpdate: Bool)
        case failed(String)
    }

    /// The server holds fewer parcels for the treatment than were sent: part
    /// of it is not on the register, so it is not said to be saved.
    struct Shortfall: Error, Equatable {
        let recorded: Int
        let sent: Int

        var text: String {
            "Сървърът е записал \(recorded) от \(sent) парцела. Натиснете «Запази» отново."
        }
    }

    mutating func key(for draft: TreatmentDraft, parcels: [String]) -> String {
        let entered = Entered(draft: draft, parcels: Set(parcels))
        if let last, last != entered { key = UUID().uuidString }
        last = entered
        return key
    }

    /// One press of «Запази» — apart from the screen, so a test can read it.
    ///
    /// ── An earlier save is settled before a changed entry goes out ──
    ///
    /// A changed entry has a new key, so the server cannot tell it from a
    /// second treatment. If the earlier save landed and only its answer was
    /// lost, sending the changed one records the treatment twice on a legal
    /// register. So the server is asked about the earlier key first:
    ///
    ///   nothing under it    → the changed entry is sent.
    ///   recorded            → that is the record. Nothing more is sent, and
    ///                         the screen says the change is not in it.
    ///   begun, not finished → the earlier entry is sent again under its own
    ///                         key, as it was, which finishes it.
    ///
    /// The same entry pressed again needs none of this: it goes out under the
    /// same key, and the server answers with what it already has.
    ///
    /// ── Kept on the phone when the server cannot be reached (#324) ──
    ///
    /// The entry's OWN send failing in a way a later send can fix — no
    /// signal, a 5xx, a 408, a 429, or a 426 for the updated app — puts it in
    /// the outbox under its own key, and the press ends there. Never while
    /// an earlier save under ANOTHER key is still unsettled: settling it
    /// needs the server, and sending the changed entry without that answer
    /// could record the treatment twice. Then, as before, the error stays on
    /// screen and «Запази» asks again.
    mutating func save(_ record: TreatmentRecord, fields: [TreatmentPlace.Field], cropLabel: String?,
                       entered draft: TreatmentDraft, with recorder: TreatmentRecorder) async -> Outcome {
        let entry = Sent(key: key(for: draft, parcels: fields.map(\.id)),
                         record: record, fields: fields, cropLabel: cropLabel)
        do {
            if let earlier = unsettled, earlier.key != entry.key {
                switch try await recorder.landing(of: earlier.key) {
                case .nothing:
                    unsettled = nil
                case .landed(let count) where count >= earlier.record.parcelIDs.count:
                    unsettled = nil
                    return .saved(earlier, changeLost: earlier.record != record)
                case .landed, .half:
                    try await send(earlier, with: recorder)
                    return .saved(earlier, changeLost: earlier.record != record)
                }
            }
        } catch let short as Shortfall {
            return .failed(short.text)
        } catch {
            return .failed(UserMessage.text(for: error))
        }
        do {
            try await send(entry, with: recorder)
            return .saved(entry, changeLost: false)
        } catch let short as Shortfall {
            return .failed(short.text)
        } catch {
            if Self.mayWait(error), await recorder.keep(entry, after: error) {
                unsettled = nil
                return .queued(entry, afterUpdate: Self.waitsForUpdate(error))
            }
            return .failed(UserMessage.text(for: error))
        }
    }

    /// May an entry whose save failed this way wait in the outbox? Only when
    /// a later send can land it: the retry policy's failures
    /// (`PendingOperations.isWorthRetrying`), and a 426 — the build turned
    /// away unread, so the updated app sends it as it stands, as the spray
    /// sheet keeps one (`ParcelOperationSheet.QueueOffer`). A refusal will be
    /// a refusal tomorrow and stays on screen, where it can be corrected.
    ///
    /// A short answer is not here: it arrives as a 201, and the person is
    /// asked to press again, which finishes it at once.
    static func mayWait(_ error: Error) -> Bool {
        if error is Shortfall { return false }
        return waitsForUpdate(error) || PendingOperations.isWorthRetrying(error)
    }

    static func waitsForUpdate(_ error: Error) -> Bool {
        if case APIClient.APIError.clientTooOld = error { return true }
        return false
    }

    private mutating func send(_ entry: Sent, with recorder: TreatmentRecorder) async throws {
        do {
            let receipt = try await recorder.record(entry.record, idempotencyKey: entry.key)
            if let count = receipt.parcelCount, count < entry.record.parcelIDs.count {
                throw Shortfall(recorded: count, sent: entry.record.parcelIDs.count)
            }
            unsettled = nil
        } catch {
            if Self.mayHaveLeftSomething(error) { unsettled = entry }
            throw error
        }
    }

    /// Whether a save that failed this way can have left anything on the
    /// server. Whatever reached it can — a refusal too: the write is one
    /// request and many transactions (a task and its lines for each block,
    /// then every line marked done), so an error part-way leaves what was
    /// committed before it. Only what never left the phone, or was turned
    /// away unread (426), cannot.
    static func mayHaveLeftSomething(_ error: Error) -> Bool {
        switch error {
        case APIClient.APIError.notSignedIn, APIClient.APIError.noFarmOpen, APIClient.APIError.clientTooOld:
            false
        default:
            true
        }
    }
}

/// Where a treatment is saved and its ДНЕВНИК pages come from: the server
/// (`LiveTreatmentRecorder`), or a test's script.
///
/// «Нов запис» opens these screens only now that all three are served — the
/// save and the read by handle (agri-saas #1758), the list showing a
/// treatment as one row (#1799), and the ДНЕВНИК for one treatment (#1822) —
/// so the phone writes no record it can neither show nor print.
protocol TreatmentRecorder: Sendable {
    /// Saves the record under its key, which is the treatment's handle from
    /// then on. The key is minted once per entry and reused on a retry, so a
    /// retry cannot save it twice.
    func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> TreatmentReceipt
    /// What the server holds under a handle.
    func landing(of handle: String) async throws -> TreatmentLanding
    /// The ДНЕВНИК pages for one treatment, as a local PDF for Quick Look.
    func document(forTreatment handle: String) async throws -> URL
    /// Keeps an entry the server could not be reached with, to be sent under
    /// its own key once it can be (#324). Says whether it is now on the
    /// phone; when it is not, the save's error is what the person sees.
    func keep(_ entry: TreatmentAttempt.Sent, after error: Error) async -> Bool
    /// How far the server got with a treatment: nil when it holds nothing
    /// under the handle (#326).
    func progress(of handle: String) async throws -> TreatmentProgress?
    /// Abandons an unfinished treatment: ADMIN only, the whole treatment,
    /// its ДНЕВНИК entries included (agri-saas #1860, owner 2026-10-15).
    func abandon(_ handle: String) async throws
}
