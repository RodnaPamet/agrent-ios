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
/// Everything the form records (agri-saas #2293): the date, the product,
/// the dose, the pest, the growth stage, the quarantine period, the
/// technique and each parcel's treated area. Not the parcel SET: adding or
/// dropping one is refused with 400 `TREATMENT_CORRECTION_FIELD_UNSUPPORTED`
/// (`parcels`), so the phone keeps the list as recorded.
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

    /// The treatment's corrections, newest first (agri-saas #2292).
    ///
    /// A READ gate, where the prefill is a write gate: anyone who can see the
    /// treatment can see that it was corrected and what it said before. That
    /// is who the owner asked it for (#392, 2026-10-22): an inspector reading
    /// a filed register.
    static func correctionsPath(_ handle: String) -> String {
        "\(TreatmentAPI.treatmentPath(handle))/corrections"
    }

    static func corrections(_ handle: String) async throws -> TreatmentCorrectionTrail {
        try await APIClient.shared.get(correctionsPath(handle), as: TreatmentCorrectionTrail.self)
    }
}

/// `GET …/corrections`: who corrected the treatment, when, which fields, and
/// the whole definition as it stood before. At most 50, newest first.
struct TreatmentCorrectionTrail: Decodable, Equatable, Sendable {
    let treatmentGroupId: String
    /// The treatment's CURRENT version.
    let version: Int
    let corrections: [Entry]

    struct Entry: Decodable, Equatable, Sendable {
        let correctedAt: Date
        /// A display name, never an id. Nil when no one can be named: a job
        /// with no actor, or an account since removed.
        let correctedBy: String?
        /// The server's field names (`occurredOn`, `phenophase`, …).
        let changedFields: [String]
        /// The definition before this correction. Read leniently: a stored
        /// one this build can't read costs only its "was" values, not the
        /// fact that a correction happened, nor the rest of the trail.
        let previous: TreatmentDefinition?

        private enum CodingKeys: String, CodingKey { case correctedAt, correctedBy, changedFields, previous }

        init(correctedAt: Date, correctedBy: String?, changedFields: [String], previous: TreatmentDefinition?) {
            self.correctedAt = correctedAt
            self.correctedBy = correctedBy
            self.changedFields = changedFields
            self.previous = previous
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            correctedAt = try c.decode(Date.self, forKey: .correctedAt)
            correctedBy = try c.decodeIfPresent(String.self, forKey: .correctedBy)
            changedFields = (try? c.decode([String].self, forKey: .changedFields)) ?? []
            previous = (try? c.decodeIfPresent(TreatmentDefinition.self, forKey: .previous)) ?? nil
        }
    }
}

/// A recorded treatment as `GET …/definition` serves it, read for what the
/// correction form shows and changes. The water rate is not read: the
/// phone's form never recorded one, and leaves it as it is.
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
    /// The farm's product, by id: a correction changes it by id too
    /// (agri-saas #2293), so only to one the farm already has.
    let productItemId: String
    let productName: String
    let pppRegistrationNo: String?
    /// A number on the wire, read through `WireDecimal` as every dose is.
    let doseValue: Decimal
    let doseUnitId: String
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

extension TreatmentDefinition {
    private enum CodingKeys: String, CodingKey {
        case treatmentGroupId, version, kind, occurredOn, applicationTechnique, targetNote
        case productItemId, productName, pppRegistrationNo, doseValue, doseUnitId
        case quarantinePeriodDays, phenophase, lines
    }

    // In an extension, so the memberwise initialiser stays for tests.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treatmentGroupId = try c.decode(String.self, forKey: .treatmentGroupId)
        version = try c.decode(Int.self, forKey: .version)
        kind = try c.decode(String.self, forKey: .kind)
        occurredOn = try c.decodeIfPresent(String.self, forKey: .occurredOn)
        applicationTechnique = try c.decodeIfPresent(String.self, forKey: .applicationTechnique)
        targetNote = try c.decodeIfPresent(String.self, forKey: .targetNote)
        productItemId = try c.decode(String.self, forKey: .productItemId)
        productName = try c.decode(String.self, forKey: .productName)
        pppRegistrationNo = try c.decodeIfPresent(String.self, forKey: .pppRegistrationNo)
        doseValue = try c.decode(WireDecimal.self, forKey: .doseValue).value
        doseUnitId = try c.decode(String.self, forKey: .doseUnitId)
        quarantinePeriodDays = try c.decodeIfPresent(Int.self, forKey: .quarantinePeriodDays)
        phenophase = try c.decodeIfPresent(String.self, forKey: .phenophase)
        lines = try c.decode([Line].self, forKey: .lines)
    }
}
