import Foundation

/// «Коригирай» on pruning, cultivation or a harvest (#439; agri-saas #2373,
/// #2375; owner 2026-10-25).
///
/// The treatment correction's conventions on the activities' own path: `GET
/// …/definition` is the activity as recorded with the GROUP's version,
/// write-gated like the PUT (403 `TREATMENT_EDIT_NOT_PERMITTED` to anyone
/// who may not correct it, the treatments' rule reused); `PUT` on the same
/// path is the correction under `If-Match: <version>`, and its 200 is the
/// corrected definition with the version moved on.
///
/// ── What can be corrected ──
///
/// The day, a harvest's total in kg, and the parcels with each one's area
/// (agri-saas #2386, #447). Not its kind (a pruning that was a harvest is
/// another record), and not a title: the journal entry's title is composed
/// by the server from the kind and the parcel, so a title field would change
/// a string no farmer sees (backend 1, 2026-10-26).
///
/// Unlike a treatment's, the parcels may come from any of the farm's blocks
/// (owner, 2026-10-26): activities aren't in the БАБХ register, which prints
/// a table per block, and the farm's diary prints one row per activity.
///
/// The address follows the row's kind, for the definition and the trail
/// alike: a bare handle on the treatments' routes is `NOT_A_TREATMENT`, a
/// treatment's on these `NOT_AN_ACTIVITY`. The two share the corrections
/// table on the server, not an endpoint: the trail's `previous` is an
/// activity's definition here, a treatment's there (backend 1, 2026-10-26).
enum ActivityCorrectionAPI {
    static func definitionPath(_ handle: String) -> String {
        "\(ActivityAPI.recordPath(tenant: FarmPath.openSlug))/\(URLEscape.segment(handle))/definition"
    }

    static func definition(_ handle: String) async throws -> ActivityDefinition {
        try await APIClient.shared.get(definitionPath(handle), as: ActivityDefinition.self)
    }

    /// A 409 `STALE_DATA` (someone corrected it meanwhile) is
    /// `APIError.conflict`, as on a treatment.
    static func correct(_ handle: String, _ correction: ActivityCorrection.Body,
                        version: Int) async throws -> ActivityDefinition {
        let corrected = try await APIClient.shared.put(definitionPath(handle), body: correction,
                                                       ifMatch: version, as: ActivityDefinition.self)
        UsageEvents.note(.treatmentCorrected)
        return corrected
    }

    /// Its corrections, newest first: a READ gate, as a treatment's trail.
    static func correctionsPath(_ handle: String) -> String {
        "\(ActivityAPI.recordPath(tenant: FarmPath.openSlug))/\(URLEscape.segment(handle))/corrections"
    }

    static func corrections(_ handle: String) async throws -> TreatmentCorrectionTrail {
        try await APIClient.shared.get(correctionsPath(handle), as: TreatmentCorrectionTrail.self)
    }
}

/// `FarmActivityDefinition`: an activity as `GET …/definition` serves it, and
/// as each of its corrections' `previous` on the trail.
struct ActivityDefinition: Decodable, Equatable, Sendable {
    let treatmentGroupId: String
    /// The group's version, sent back as `If-Match`. 0 for one recorded
    /// before the group row existed.
    let version: Int
    /// `PRUNE`, `CULTIVATE` or `HARVEST`.
    let kind: String
    /// `YYYY-MM-DD`, the farm day. Null only while no line is marked.
    let occurredOn: String?
    /// A harvest's one total in kg. Nil on other work, and on a harvest
    /// whose total was never recorded — which is not a harvest of nothing.
    let harvestKg: Decimal?
    let lines: [Line]

    struct Line: Decodable, Equatable, Sendable {
        let parcelId: String
        let parcelName: String?
        /// The parcel's block. Every parcel has one since agri-saas #2305;
        /// nullable in the spec all the same.
        var locationId: String? = nil
        /// Hectares. NIL MEANS THE WHOLE PARCEL, not an empty value.
        var treatedAreaHa: Double? = nil
    }

    var activity: ActivityKind? { ActivityKind(rawValue: kind) }

    init(treatmentGroupId: String, version: Int, kind: String, occurredOn: String?,
         harvestKg: Decimal?, lines: [Line]) {
        self.treatmentGroupId = treatmentGroupId
        self.version = version
        self.kind = kind
        self.occurredOn = occurredOn
        self.harvestKg = harvestKg
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey {
        case treatmentGroupId, version, kind, occurredOn, harvestKg, lines
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treatmentGroupId = try c.decode(String.self, forKey: .treatmentGroupId)
        version = try c.decode(Int.self, forKey: .version)
        kind = try c.decode(String.self, forKey: .kind)
        occurredOn = try c.decodeIfPresent(String.self, forKey: .occurredOn)
        // A number on the wire, read through `WireDecimal` as every quantity is.
        harvestKg = try c.decodeIfPresent(WireDecimal.self, forKey: .harvestKg)?.value
        lines = (try? c.decode([Line].self, forKey: .lines)) ?? []
    }
}
