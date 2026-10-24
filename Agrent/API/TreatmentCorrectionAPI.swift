import Foundation

/// «Коригирай» on a recorded treatment (agrent-ios #392; agri-saas #2283,
/// #2287; owner 2026-10-24).
///
/// ── One path, two methods ──
///
/// `GET …/definition` is the treatment as recorded, for the form to start
/// from, with the GROUP's `version`. A treatment is one row with that
/// version since agri-saas #2279, however many blocks and parcels it spans.
/// `PUT` on the same path is the correction, under `If-Match: <version>`.
/// Its 200 is the corrected definition with the version moved on, so a
/// second correction needs no read in between.
///
/// The GET is gated like the write: it answers 403
/// `TREATMENT_EDIT_NOT_PERMITTED` to anyone who may not correct. So it is
/// never asked whether «Коригирай» should show — `TreatmentCorrection.offered`
/// decides that from the journal row.
///
/// ── What can be corrected ──
///
/// Today: the date, the pest, the growth stage, the quarantine period and
/// the technique (and the title, which this app's form doesn't have). A
/// changed product, dose or parcel list is refused with 400
/// `TREATMENT_CORRECTION_FIELD_UNSUPPORTED`. The phone shows those locked
/// rather than offering a change the server would refuse (owner, 2026-10-24).
enum TreatmentCorrectionAPI {
    static func definitionPath(_ handle: String) -> String {
        "\(TreatmentAPI.treatmentPath(handle))/definition"
    }

    static func definition(_ handle: String) async throws -> TreatmentDefinition {
        try await APIClient.shared.get(definitionPath(handle), as: TreatmentDefinition.self)
    }

    /// The correction under the version it was made against. A 409
    /// `STALE_DATA` (someone corrected it meanwhile) is `APIError.conflict`.
    static func correct(_ handle: String, _ correction: TreatmentCorrection.Body,
                        version: Int) async throws -> TreatmentDefinition {
        try await APIClient.shared.put(definitionPath(handle), body: correction,
                                       ifMatch: version, as: TreatmentDefinition.self)
    }
}

/// A recorded treatment as `GET …/definition` serves it, read for what the
/// correction form shows. The product, dose and water rate ids are not
/// read: the form never sends them back (`TreatmentCorrection.Body`).
struct TreatmentDefinition: Decodable, Equatable, Sendable {
    let treatmentGroupId: String
    /// The group's version, sent back as `If-Match`. 0 for a treatment
    /// recorded before the group row existed.
    let version: Int
    /// `SPRAY` or `FERTILIZE`.
    let kind: String
    /// `YYYY-MM-DD`, the farm day. Null only while no line is marked.
    let occurredOn: String?
    let applicationTechnique: String?
    let targetNote: String?
    let productName: String
    let pppRegistrationNo: String?
    /// As captured on the day. Nil means nothing was captured, which the
    /// form shows as empty, never as the product's current period.
    let quarantinePeriodDays: Int?
    let phenophase: String?
    let lines: [Line]

    struct Line: Decodable, Equatable, Sendable {
        let parcelId: String
        let parcelName: String
        /// Hectares. NIL MEANS THE WHOLE PARCEL, not an empty value.
        let treatedAreaHa: Double?
    }

    var treatmentKind: TreatmentDraft.Kind? { TreatmentDraft.Kind(rawValue: kind) }
}
