import Foundation

/// «Ново мероприятие»'s save, and the read that says whether a save landed
/// (agrent-ios#293; agri-saas #1740).
///
/// ── The key is the treatment's handle ──
///
/// `POST /journal/treatments` records one treatment, done, on parcels from
/// any number of blocks. Its `Idempotency-Key` comes back as
/// `treatmentGroupId` and addresses the treatment from then on, so the phone
/// knows the handle before the answer arrives: a lost answer does not cost
/// it the id.
///
/// ── A reused key is REPLAYED, whatever the body (owner, 2026-10-14) ──
///
/// The server does not compare bodies (agri-saas #1765). A changed entry
/// sent under the old key is answered with the ORIGINAL treatment and
/// records nothing. So a changed entry goes out under a new key — and
/// before it does, the phone asks what the old one left (`landing`), or a
/// save whose answer was lost would be recorded twice. `TreatmentAttempt`
/// keeps both rules.
///
/// Never sent from development, CI or the screenshot harness: it writes a
/// farm's legal register.
enum TreatmentAPI {
    private static var base: String { recordPath(tenant: FarmPath.openSlug) }

    static var recordPath: String { base }

    /// The save's path on a farm named explicitly: a queued treatment's,
    /// which goes to the farm it was made on whichever is open when it is
    /// sent (#324; `PendingOperation.tenantSlug`).
    static func recordPath(tenant: String?) -> String {
        "\(FarmPath.root(for: tenant))/journal/treatments"
    }

    /// The handle sits in the PATH. It is the phone's own key and names
    /// nobody — see `JournalAPI.path` on what a URL may carry.
    static func treatmentPath(_ handle: String) -> String {
        "\(base)/\(URLEscape.segment(handle))"
    }

    /// The ДНЕВНИК pages for one treatment (agri-saas #1822): the per-block
    /// register's document, limited to this treatment's rows across every
    /// block it touched.
    static func documentPath(_ handle: String) -> String {
        "\(treatmentPath(handle))/farm-record"
    }

    /// The request body (`RecordDiaryTreatment`).
    ///
    /// BY NAME, never by id, as the spray sheet sends it (#237): the server
    /// finds the farm's product of that name or creates it, and
    /// `TreatmentRecord.productName` is the stored name on a match. One dose
    /// for either kind — the route files it as the product's or the
    /// fertiliser's by `kind`.
    struct Body: Encodable, Equatable, Sendable {
        let kind: String
        /// A calendar DAY, never an instant a time zone could move.
        let occurredOn: String
        /// One flat list across blocks; the server groups it.
        let parcelIds: [String]
        let productName: String?
        let fertilizerName: String?
        /// Read by the server only when the name has to CREATE a plant
        /// protection product, and ignored on a match: an operation never
        /// rewrites a stored registration.
        let pppRegistrationNo: String?
        /// The period AS IT APPLIED ON THE DAY, kept on every line this
        /// treatment records (agri-saas #1775), for a product the farm has as
        /// much as for a new one — so the ДНЕВНИК prints the period typed
        /// here, and the earliest-harvest date from it, even after the
        /// product's own period changes. A new product also takes it as its
        /// registration; a known one is not rewritten.
        let quarantinePeriodDays: Int?
        let targetNote: String?
        let doseValue: Decimal
        let doseUnitId: String
        /// The SLUG — see `ApplicationTechnique`.
        let applicationTechnique: String?
        /// «Фенофаза/BBCH», stored on every line (agri-saas #2083). Left
        /// out when not given, which the server stores as "not captured".
        /// It prints in the scouting table's «Фенофаза/BBCH», on a row
        /// derived from the treatment (agri-saas #2089), not in the
        /// chemical table, which has no such column.
        let phenophase: String?
        /// Each parcel's treated area in HECTARES (agri-saas #2086): a
        /// refinement of `parcelIds`, which still names every parcel.
        ///
        /// A parcel treated whole goes out as its own exact area, not left
        /// out (owner, 2026-10-25): the register keeps the number, so the row
        /// says what was treated on the day even if the parcel is re-measured
        /// later. The exact area, not the rounded one the form shows, so it
        /// never exceeds the parcel (`TREATMENT_AREA_EXCEEDS_PARCEL` compares
        /// exactly). Only a parcel with no recorded area is left out, as the
        /// whole parcel: there is no number to keep. Nil when that is every
        /// parcel.
        let parcels: [ParcelArea]?

        struct ParcelArea: Encodable, Equatable, Sendable {
            let parcelId: String
            let treatedAreaHa: Double
        }

        init(_ record: TreatmentRecord) {
            let spraying = record.kind == .spray
            kind = record.kind.rawValue
            occurredOn = BgDate.isoDay(record.date)
            parcelIds = record.parcelIDs
            productName = spraying ? record.productName : nil
            fertilizerName = spraying ? nil : record.productName
            pppRegistrationNo = record.newProduct?.pppRegistrationNo
            quarantinePeriodDays = record.quarantineDays
            // An empty note is no note: the schema caps its length and
            // gives it no minimum, and "" would print as a filled column.
            targetNote = record.pest.flatMap { $0.isEmpty ? nil : $0 }
            doseValue = record.dose
            doseUnitId = record.doseUnitID
            applicationTechnique = record.technique?.rawValue
            phenophase = record.phenophase
            // In `parcelIds`' order, each once: the server refuses an id it
            // doesn't list there, or one listed twice.
            let areas = record.parcelIDs.compactMap { id in
                (record.treatedAreas[id] ?? record.parcelAreas[id]).map { ParcelArea(parcelId: id, treatedAreaHa: $0) }
            }
            parcels = areas.isEmpty ? nil : areas
        }
    }

    /// Sends the treatment under its key.
    static func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> TreatmentReceipt {
        let data = try await APIClient.shared.postReturningData(
            recordPath, body: Body(record), idempotencyKey: idempotencyKey)
        return receipt(from: data, key: idempotencyKey)
    }

    /// What a save that LANDED reports, read leniently: a 201 whose body
    /// cannot be read is still a treatment on the register, and its handle
    /// is the key it went out under (`FieldOperationAPI.landed`). A plain
    /// decoder for the reason given there.
    static func receipt(from data: Data, key: String) -> TreatmentReceipt {
        struct Wire: Decodable {
            let treatmentGroupId: String?
            let parcelCount: Int?
        }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return TreatmentReceipt(handle: wire?.treatmentGroupId ?? key, parcelCount: wire?.parcelCount)
    }

    /// What the server holds under a handle.
    static func landing(of handle: String) async throws -> TreatmentLanding {
        do {
            let data = try await APIClient.shared.data(for: treatmentPath(handle))
            return try landing(from: data)
        } catch let error where isNothingRecorded(error) {
            return .nothing
        }
    }

    /// STRICT, unlike `receipt`: `complete` decides between never writing
    /// again and sending again, and a guess at it is a treatment recorded
    /// twice or left half done.
    /// The treatment's field-operation tasks, one per block (#399): what
    /// «Виж на картата» reads its parcels from.
    static func taskIDs(from data: Data) throws -> [String] {
        struct Summary: Decodable { let taskIds: [String] }
        return try JSONDecoder().decode(Summary.self, from: data).taskIds
    }

    static func landing(from data: Data) throws -> TreatmentLanding {
        struct Summary: Decodable {
            let parcelCount: Int
            let complete: Bool
        }
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        return summary.complete ? .landed(parcelCount: summary.parcelCount) : .half
    }

    /// How far the server got, for the entry's screen (#326). nil on the
    /// route's own 404: nothing under the handle, which after an abandon is
    /// what the server says too.
    static func progress(of handle: String) async throws -> TreatmentProgress? {
        do {
            return try progress(from: try await APIClient.shared.data(for: treatmentPath(handle)))
        } catch let error where isNothingRecorded(error) {
            return nil
        }
    }

    /// STRICT, as `landing` is: the counts decide whether an administrator
    /// is offered the abandon, which removes ДНЕВНИК entries.
    static func progress(from data: Data) throws -> TreatmentProgress {
        try JSONDecoder().decode(TreatmentProgress.self, from: data)
    }

    /// Abandons an unfinished treatment (agri-saas #1860). The 200's counts
    /// aren't read: the entry's screen closes and the list is read again.
    static func abandon(_ handle: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(treatmentPath(handle))
    }

    /// The treatment's ДНЕВНИК pages, kept as the per-block register is
    /// (`FarmRecordAPI.keep`): bytes inline, checked for `%PDF`, removed when
    /// the sheet closes. A GET, and a pure read — the server files nothing.
    static func document(forTreatment handle: String) async throws -> URL {
        let (data, served) = try await APIClient.shared.getForDocument(documentPath(handle))
        return try FarmRecordAPI.keep(data, named: FarmRecordAPI.fileName(served, fallback: "dnevnik-\(handle).pdf"))
    }

    /// Only the route's OWN 404. One without the code is a server that does
    /// not have the route, or a farm it will not show: it says nothing about
    /// the treatment, and read as "nothing landed" it would let a second one
    /// be written.
    static func isNothingRecorded(_ error: Error) -> Bool {
        if case APIClient.APIError.http(404, "TREATMENT_NOT_FOUND"?, _, _, _) = error { return true }
        return false
    }
}

/// What the server answered a save with.
struct TreatmentReceipt: Equatable, Sendable {
    let handle: String
    /// Lines the server holds for the treatment across every block. nil when
    /// the answer could not be read.
    let parcelCount: Int?
}

/// What the server holds under a treatment's handle
/// (`GET /journal/treatments/{handle}`): three answers, and each asks for a
/// different next step — see `TreatmentAttempt.save`.
enum TreatmentLanding: Equatable, Sendable {
    /// 404 `TREATMENT_NOT_FOUND`: nothing was recorded under it.
    case nothing
    /// Recorded in full: every one of this many parcels has its ДНЕВНИК
    /// entry.
    case landed(parcelCount: Int)
    /// Recorded in part — a block not written, or lines written and not yet
    /// marked done, which is what puts them on the register. The same key
    /// sent again finishes the rest.
    case half
}

/// How far the server got with a treatment (`GET /journal/treatments/{handle}`,
/// agri-saas #1758): the counts behind `TreatmentLanding`, for a screen that
/// says them.
struct TreatmentProgress: Decodable, Equatable, Sendable {
    /// The treatment's lines, one per parcel, across every block.
    let parcelCount: Int
    /// Those marked done: each has its ДНЕВНИК entry.
    let completedCount: Int
    /// Every line done. Only an incomplete treatment can be abandoned.
    let complete: Bool
}

/// The recorder «Нов запис» opens with: the server, through `TreatmentAPI`.
struct LiveTreatmentRecorder: TreatmentRecorder {
    func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> TreatmentReceipt {
        try await TreatmentAPI.record(record, idempotencyKey: idempotencyKey)
    }

    func landing(of handle: String) async throws -> TreatmentLanding {
        try await TreatmentAPI.landing(of: handle)
    }

    func document(forTreatment handle: String) async throws -> URL {
        try await TreatmentAPI.document(forTreatment: handle)
    }

    func progress(of handle: String) async throws -> TreatmentProgress? {
        try await TreatmentAPI.progress(of: handle)
    }

    func abandon(_ handle: String) async throws {
        try await TreatmentAPI.abandon(handle)
    }

    /// Into the outbox, under the entry's own key (#324).
    ///
    /// ── The answer it failed with is the outbox's answer too ──
    ///
    /// The live save and the drain post to the same route from the same
    /// build on the same budget, as the spray sheet's save and its queue do
    /// (`ParcelOperationSheet.queueForLater`). A 429 closes the outbox's
    /// pause before the row joins it, so the next foreground does not spend
    /// a request to be told the same thing; a 426 tells the outbox this
    /// build is retired, so its banner says the entry waits for the update.
    ///
    /// ── Said to be kept only once it is on disk ──
    ///
    /// `PendingOperations.enqueue` cannot throw — it logs — so the row is
    /// read back. A screen saying «чака изпращане» over an entry that is not
    /// there would be the one lie this path exists to prevent. Nobody known
    /// to be signed in keeps nothing either: a row must name whose it is
    /// (`PendingOperation.ownerUserID`), and the save's error stays on
    /// screen instead.
    ///
    /// ── The farm is read before anything is awaited ──
    ///
    /// The row goes back to the farm the entry was made on, which is the one
    /// open while its sheet was. `OutboxStore.enqueue` would otherwise stamp
    /// whichever farm is open once the encoding returns. With none open the
    /// row would have nowhere to go, so it is not kept.
    @MainActor
    func keep(_ entry: TreatmentAttempt.Sent, after error: Error) async -> Bool {
        guard let farm = FarmPath.openSlug, let owner = SessionIdentity.shared.userID,
              let body = try? await APIClient.shared.encodeBody(TreatmentAPI.Body(entry.record))
        else { return false }
        let outbox = OutboxStore.shared
        outbox.pause.absorb(error)
        outbox.absorbClientTooOld(error)
        let total = TreatmentPlace.total(entry.fields, treated: entry.record.treatedAreas)
        let blocks = entry.fields.reduce(into: [String]()) { names, field in
            if !names.contains(field.blockName) { names.append(field.blockName) }
        }
        let row = PendingOperation.treatment(
            handle: entry.key,
            .init(kind: entry.record.kind.rawValue, productName: entry.record.productName,
                  occurredOn: BgDate.isoDay(entry.record.date), parcelCount: entry.record.parcelIDs.count,
                  areaHa: total.withoutArea < total.parcels ? total.area.wireHectares : nil,
                  blockNames: blocks),
            ownerUserID: owner, farm: farm, payload: body, reason: UserMessage.text(for: error))
        await outbox.enqueue(row)
        return await PendingOperations.shared.row(entry.key) != nil
    }
}
