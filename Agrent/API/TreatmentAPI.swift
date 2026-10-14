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
    private static var base: String { "\(FarmPath.root)/journal/treatments" }

    static var recordPath: String { base }

    /// The handle sits in the PATH. It is the phone's own key and names
    /// nobody — see `JournalAPI.path` on what a URL may carry.
    static func treatmentPath(_ handle: String) -> String {
        "\(base)/\(URLEscape.segment(handle))"
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
        /// protection product, and ignored on a match.
        let pppRegistrationNo: String?
        let quarantinePeriodDays: Int?
        let targetNote: String?
        let doseValue: Decimal
        let doseUnitId: String
        /// The SLUG — see `ApplicationTechnique`.
        let applicationTechnique: String?

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
    static func landing(from data: Data) throws -> TreatmentLanding {
        struct Summary: Decodable {
            let parcelCount: Int
            let complete: Bool
        }
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        return summary.complete ? .landed(parcelCount: summary.parcelCount) : .half
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
    /// Recorded, on this many parcels.
    case landed(parcelCount: Int)
    /// Begun and not finished. The same key sent again finishes it.
    case half
}
