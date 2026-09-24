import Foundation

/// One parcel's satellite readings.
///
/// FLAT — no envelope, no nesting. Every key is always present and an
/// absent value is `null`, never a missing key. Taken from the server's
/// `ParcelRiskResult` rather than inferred from a sample, because the
/// last four wire shapes this app guessed at were wrong and one of them
/// meant the product picker returned nothing for as long as it existed.
struct ParcelRisk: Decodable, Identifiable, Equatable, Sendable {
    let parcelId: String
    let name: String
    let areaHa: Double?
    let cropType: String?

    /// Is Earth Engine set up for this DEPLOYMENT?
    ///
    /// ── This is the field that separates two identical-looking absences ──
    ///
    /// A parcel with no geometry returns `configured: true` with null
    /// readings and `unknown` levels. A deployment without Earth Engine
    /// returns `configured: false` with exactly the same nulls and the
    /// same `unknown`. Every other field is identical, so this is the only
    /// thing that can tell a farmer "your parcel has no boundary" from
    /// "this farm has no satellite analysis at all" — which want
    /// completely different actions.
    let configured: Bool

    /// The raw index means, to 3dp. Null when there is no reading.
    ///
    /// ── A MEAN over the polygon, not a pixel ──
    ///
    /// The map overlay draws NDVI per-pixel across the whole location;
    /// this is one number averaged over this parcel's boundary. A farmer
    /// comparing a bright patch on the map against this number will find
    /// them different and both are correct. The screen says so rather than
    /// letting them discover it.
    let ndvi: Double?
    let ndmi: Double?

    let vegetation: RiskLevel
    let moisture: RiskLevel
    /// The WORSE of the two, computed server-side. Not recomputed here —
    /// two implementations of one rule is how they drift.
    let overall: RiskLevel

    /// A CALENDAR DAY. Produced by the same function the tile routes use,
    /// so the risk page and the satellite overlay cannot disagree about
    /// when a pass happened. Parsed with `BgDate.parseISODay`; parsing it
    /// as an instant shifts it a timezone.
    let acquiredDate: String?

    /// A full ISO timestamp — the other shape, in the same object.
    let generatedAt: Date

    var id: String { parcelId }

    var acquired: Date? { acquiredDate.flatMap(BgDate.parseISODay) }

    /// How old the reading is, measured server-side to server-side.
    ///
    /// Both ends come from the server for the same reason the price
    /// staleness does: a rural device can be hours off, and a wrong clock
    /// must not be able to relabel a three-week-old pass as current.
    var staleDays: Int? {
        Staleness.days(generatedAt: generatedAt, lastObservedAt: acquiredDate)
    }

    /// Why there is no reading, in the farmer's terms.
    ///
    /// nil when there IS one. The two absences are indistinguishable in
    /// every field except `configured`, so this is where that difference
    /// becomes a sentence instead of a shrug.
    var absenceReason: String? {
        guard !overall.isReading else { return nil }
        if !configured {
            return "Сателитният анализ не е настроен за това стопанство."
        }
        return "Няма безоблачно заснемане на този парцел в последните дни."
    }
}

enum FarmRiskAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)" }

    /// Per-parcel readings. ETagged server-side and cached per
    /// (tenant, parcel, day) for six hours, so `If-None-Match` is worth
    /// sending — `APIClient` already does.
    ///
    /// The parcel id is a PATH SEGMENT, not a query parameter. It was
    /// `?parcelId=` and was moved before this app ever called it: Apple's
    /// CFNetwork writes full URLs to the unified log unsuppressably, so an
    /// id in a query string is an id in the device log.
    static func analysisPath(_ parcelID: String) -> String {
        let escaped = parcelID.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? parcelID
        return "\(base)/agro/parcels/\(escaped)/analysis"
    }

    /// Which parcels have already been asked about.
    ///
    /// Read rather than remembered. The web page originally tracked "sent"
    /// in component-local state, which died on unmount — so navigating
    /// away and back re-enabled a button whose write the database then
    /// refused, and the operator was told off for retrying something they
    /// had no way to see they had done.
    static var leadsPath: String { "\(base)/insurance/leads" }

    static func decodeAnalysis(from data: Data) async throws -> ParcelRisk {
        try await APIClient.shared.decode(data, as: ParcelRisk.self)
    }

    static func decodeLeads(from data: Data) async throws -> InsuranceLeads {
        try await APIClient.shared.decode(data, as: InsuranceLeads.self)
    }

    /// Ask an insurer about one parcel.
    ///
    /// ── IRREVERSIBLE, and there is no undo by decision ──
    ///
    /// Unique per (parcel, tenant) at the database level, with no DELETE
    /// and no withdraw. A 15-minute undo was specified and then dropped by
    /// the owner, so the confirmation in front of this is the ONLY
    /// protection a farmer has. It names the parcel and says the ask
    /// cannot be taken back, because after this there is nowhere to say it.
    ///
    /// No `Idempotency-Key`: the route does not read one and does not need
    /// to. The (parcel, tenant) pair IS the natural key, so a replay
    /// returns 409 rather than creating a second lead — which is why the
    /// 409 is success-on-replay below and not a failure.
    static func createLead(parcelID: String) async throws {
        _ = try await APIClient.shared.post(
            leadsPath, body: CreateLead(parcelId: parcelID),
            as: EmptyResponse.self, idempotencyKey: UUID().uuidString
        )
    }

    /// 409 means "this parcel was already asked about", not "the request
    /// failed". Treating it as an error would tell a farmer their ask did
    /// not go through when it went through the first time — and then
    /// invite the retry that produces the same 409 forever.
    /// MATCHES `.conflict`, NOT `.http(409)`.
    ///
    /// This read `.http(status:)` and compared it to 409, which cannot
    /// happen: `APIClient.send` intercepts 409 two cases above its default
    /// and throws `.conflict` instead, so the guard was dead the day it was
    /// written and every test that covered it hand-built a value this
    /// client never produces.
    ///
    /// What a farmer got instead of "already asked" was the stale-edit
    /// sentence — «Записът е променен на сървъра, докато го редактирахте.»
    /// — on a screen with no editing, for an ask that had succeeded, with
    /// the button still live to retry the 409 forever.
    static func isAlreadyAsked(_ error: Error) -> Bool {
        if case APIClient.APIError.conflict = error { return true }
        // Kept for a server that ever answers 409 through the generic path.
        if case APIClient.APIError.http(let status, _, _, _) = error { return status == 409 }
        return false
    }
}

struct CreateLead: Encodable, Sendable {
    let parcelId: String
}

/// Which parcels have already been asked about.
///
/// READ, never remembered. The web page tracked "sent" in component-local
/// state; it died on unmount, so navigating away and back re-enabled a
/// button whose write the database then refused, and the operator was
/// told off for retrying something they had no way to see they had done.
struct InsuranceLeads: Decodable, Equatable, Sendable {
    let parcelIds: [String]
}
