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
/// Everything the form records (agri-saas #2293, #2304): the date, the
/// product, the dose, the pest, the growth stage, the quarantine period, the
/// technique, and the parcels with each one's treated area. A parcel may be
/// dropped, or added from the treatment's own blocks; not every parcel
/// (`TREATMENT_CORRECTION_WOULD_EMPTY`), and not one of another block
/// (`TREATMENT_CORRECTION_NEW_BLOCK`).
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
        /// The same for pruning, cultivation or a harvest, read from their own
        /// trail (`ActivityCorrectionAPI.corrections`, agri-saas #2375) in this
        /// one shape: an activity's definition, which has no product to read
        /// as a treatment's.
        let previousActivity: ActivityDefinition?

        private enum CodingKeys: String, CodingKey { case correctedAt, correctedBy, changedFields, previous }

        init(correctedAt: Date, correctedBy: String?, changedFields: [String], previous: TreatmentDefinition?,
             previousActivity: ActivityDefinition? = nil) {
            self.correctedAt = correctedAt
            self.correctedBy = correctedBy
            self.changedFields = changedFields
            self.previous = previous
            self.previousActivity = previousActivity
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            correctedAt = try c.decode(Date.self, forKey: .correctedAt)
            correctedBy = try c.decodeIfPresent(String.self, forKey: .correctedBy)
            changedFields = (try? c.decode([String].self, forKey: .changedFields)) ?? []
            previous = (try? c.decodeIfPresent(TreatmentDefinition.self, forKey: .previous)) ?? nil
            // Only where it isn't a treatment's, and only of the three kinds:
            // an activity's few fields would read out of any definition.
            let activity = previous == nil
                ? (try? c.decodeIfPresent(ActivityDefinition.self, forKey: .previous)) ?? nil : nil
            previousActivity = activity?.activity == nil ? nil : activity
        }
    }
}

/// A recorded treatment as `GET …/definition` serves it, read for what the
/// correction form shows and changes, and as each correction's `previous`
/// in the trail. The water rate is read for the trail only: the phone's form
/// never records one, and leaves it as it is.
struct TreatmentDefinition: Decodable, Equatable, Sendable {
    let treatmentGroupId: String
    /// The group's version, sent back as `If-Match`. 0 for a treatment
    /// recorded before the group row existed.
    let version: Int
    /// `SPRAY` or `FERTILIZE`.
    let kind: String
    /// `YYYY-MM-DD`, the farm day. Null only while no line is marked.
    let occurredOn: String?
    /// The treatment's title, kept when it is finished (`Body(resuming:)`).
    var title: String? = nil
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
    /// The dose unit's symbol, beside its id (agri-saas #2298). Optional:
    /// a correction filed before it stored a `previous` without it, and a
    /// trail keeps what was stored.
    let doseUnitSymbol: String?
    /// The water rate, for the trail's «Беше: …». Nil is none recorded.
    let waterRateValue: Decimal?
    let waterRateUnitSymbol: String?
    /// As captured on the day. Nil means nothing was captured, which the
    /// form shows as empty, never as the product's current period.
    let quarantinePeriodDays: Int?
    let phenophase: String?
    let lines: [Line]

    struct Line: Decodable, Equatable, Sendable {
        let parcelId: String
        let parcelName: String
        /// The parcel's block: the treatment's blocks are the only ones a
        /// correction may add a parcel in (agri-saas #2304). Required since
        /// agri-saas #2305: `Parcel.locationId` is NOT NULL, so every parcel
        /// is in a block, and the spec now says so.
        let locationId: String
        /// Hectares. NIL MEANS THE WHOLE PARCEL, not an empty value.
        let treatedAreaHa: Double?
    }

    var treatmentKind: TreatmentDraft.Kind? { TreatmentDraft.Kind(rawValue: kind) }
}

extension TreatmentDefinition {
    private enum CodingKeys: String, CodingKey {
        case treatmentGroupId, version, kind, occurredOn, title, applicationTechnique, targetNote
        case productItemId, productName, pppRegistrationNo, doseValue, doseUnitId, doseUnitSymbol
        case waterRateValue, waterRateUnitSymbol
        case quarantinePeriodDays, phenophase, lines
    }

    // In an extension, so the memberwise initialiser stays for tests.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treatmentGroupId = try c.decode(String.self, forKey: .treatmentGroupId)
        version = try c.decode(Int.self, forKey: .version)
        kind = try c.decode(String.self, forKey: .kind)
        occurredOn = try c.decodeIfPresent(String.self, forKey: .occurredOn)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        applicationTechnique = try c.decodeIfPresent(String.self, forKey: .applicationTechnique)
        targetNote = try c.decodeIfPresent(String.self, forKey: .targetNote)
        productItemId = try c.decode(String.self, forKey: .productItemId)
        productName = try c.decode(String.self, forKey: .productName)
        pppRegistrationNo = try c.decodeIfPresent(String.self, forKey: .pppRegistrationNo)
        doseValue = try c.decode(WireDecimal.self, forKey: .doseValue).value
        doseUnitId = try c.decode(String.self, forKey: .doseUnitId)
        doseUnitSymbol = (try? c.decodeIfPresent(String.self, forKey: .doseUnitSymbol)) ?? nil
        waterRateValue = ((try? c.decodeIfPresent(WireDecimal.self, forKey: .waterRateValue)) ?? nil)?.value
        waterRateUnitSymbol = (try? c.decodeIfPresent(String.self, forKey: .waterRateUnitSymbol)) ?? nil
        quarantinePeriodDays = try c.decodeIfPresent(Int.self, forKey: .quarantinePeriodDays)
        phenophase = try c.decodeIfPresent(String.self, forKey: .phenophase)
        lines = try c.decode([Line].self, forKey: .lines)
    }
}
