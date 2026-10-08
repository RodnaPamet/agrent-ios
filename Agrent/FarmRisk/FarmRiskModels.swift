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
    private static var base: String { "\(FarmPath.root)" }

    /// Per-parcel readings. ETagged server-side and cached per
    /// (tenant, parcel, day) for six hours. `If-None-Match` would be worth
    /// sending, and NOTHING SENDS IT: that used to happen invisibly through
    /// URLSession's disk cache, which #134 turned off app-wide. A full 200
    /// every time is the accepted cost; `ResponseCache` covers offline.
    ///
    /// The parcel id is a PATH SEGMENT, not a query parameter. It was
    /// `?parcelId=` and was moved before this app ever called it: Apple's
    /// CFNetwork writes full URLs to the unified log unsuppressably, so an
    /// id in a query string is an id in the device log.
    ///
    /// Escaped once, by `URLEscape.segment`. It was escaped against
    /// `.alphanumerics` and then again by `url(for:)`, so `par_holes` went
    /// out as `par%255Fholes` — agrent-ios#122.
    static func analysisPath(_ parcelID: String) -> String {
        "\(base)/agro/parcels/\(URLEscape.segment(parcelID))/analysis"
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
    /// NOT unique per (parcel, tenant) any more, and this docblock said it
    /// was for two days after it stopped being true.
    ///
    /// The unique index on `(parcelId, inquirerTenantId)` was dropped
    /// server-side on 2026-09-24 so that a farmer could re-ask with a
    /// corrected land size. Several asks per parcel are now expected, and the
    /// form above already treats `alreadyAsked` as a MARK rather than a
    /// filter — that part was fixed when the change landed. This comment was
    /// not, and neither were three equivalents in the server's own repo,
    /// which is where the claim came from.
    ///
    /// Worth keeping as the shape rather than the incident: a true-sounding
    /// sentence about a constraint that no longer exists is indistinguishable
    /// from a true one, and nothing fails when it goes stale.
    ///
    /// WHAT IS STILL TRUE: an ask cannot be WITHDRAWN. There is no DELETE and
    /// no PATCH, and the operator has already been emailed. So the
    /// confirmation says that and stops there — it must not also imply
    /// finality, because discouraging the correction is the harm.
    ///
    /// The `Idempotency-Key` IS read by the route now (1–128 characters,
    /// `[A-Za-z0-9_-]`, which a UUID satisfies). A fresh one per attempt is
    /// deliberate and correct here: with the unique gone, a repeat ask is a
    /// NEW lead with corrected figures, not a replay to be collapsed. Keeping
    /// a key across a retry would be right only for re-sending the SAME
    /// figures after a failure, which this form has no path to.
    /// Returns what the SERVER computed, which is what gets stored and
    /// emailed — never what the app previewed.
    @discardableResult
    static func createLead(_ lead: CreateLead,
                           idempotencyKey: String) async throws -> CreatedLead {
        try await APIClient.shared.post(
            leadsPath, body: lead,
            as: CreatedLead.self, idempotencyKey: idempotencyKey
        )
    }

    // `isAlreadyAsked` WAS HERE, and it is deleted rather than kept.
    //
    // It mapped a 409 to success-on-replay, which was right while the unique
    // index existed. The route has no conflict path at all now — the spec
    // documents 201, 400, 401, 403, 404, 426, 429 and 500 for this operation
    // and no 409 — and the one uniqueness catch left server-side is an
    // idempotency race that re-reads the winner and answers 201.
    //
    // So it was a guard that could no longer fire, which this repo has spent
    // a week learning to treat as a defect in its own right rather than as
    // harmless insurance. It also had that property once before, for a
    // different reason: it originally compared `.http(409)` when `APIClient`
    // intercepts 409 and throws `.conflict`, so it was dead the day it was
    // written and its tests hand-built a value this client never produces.
    //
    // Two facts it knew, kept so they are not rediscovered. A 409 reached a
    // farmer as «Записът е променен на сървъра, докато го редактирахте.» —
    // the stale-edit sentence, on a screen with no editing. And
    // `APIClient.send` intercepts 409 before its default case, so anything
    // matching on `.http(409)` for this client is unreachable.
    //
    //     git show 58e744d:Agrent/FarmRisk/FarmRiskModels.swift
}

/// What the server answered, and the only figures a farmer may be shown.
///
/// The request carries NO price and the schema strips one if sent: the server
/// recomputes from the four inputs. So a local preview is an estimate and this
/// is the price. When they differ — a phone carrying a stale tariff against a
/// newer one — THIS wins, and the screen has to show it rather than leaving
/// the estimate up beside a lead that was priced differently.
struct CreatedLead: Decodable, Equatable, Sendable {
    let id: String
    let status: String

    /// Absent when the ask carried no quote — a message-only enquiry, which
    /// still works exactly as it did. `quote` is not in the response's
    /// `required` list.
    let quote: ServerQuote?

    struct ServerQuote: Decodable, Equatable, Sendable {
        let premiumCents: Int
        let instalmentsCents: [Int]
        let tariffBp: Int
        /// Which engine priced it. Not shown; recorded because a figure a
        /// farmer disputes three weeks later is answerable only if the
        /// version that produced it is known.
        ///
        /// An INTEGER, as the spec has it (required) — and as the catalogue
        /// already reads it (`InsuranceCatalogue`). It was `String?`, so a
        /// real answer would have failed to decode AFTER the lead was made:
        /// the farmer told it failed, and each retry — same key, so a replay
        /// rather than a second lead — failing the same way (agrent-ios#182).
        let engineVersion: Int?
    }
}

struct CreateLead: Encodable, Sendable {
    let parcelId: String

    /// REQUIRED, 1–2000 characters, and its absence is why this feature has
    /// never once reached the server.
    ///
    /// The app sent `{ parcelId }` alone from the day the ask shipped.
    /// `CreateInsuranceLeadSchema` rejects that body outright —
    /// `message invalid_type` — so every enquiry a farmer made 400'd. The
    /// test that covered this encoded the struct and asserted its shape,
    /// which pinned the app's wrong assumption rather than the server's
    /// requirement, and the standing rule never to fire this POST at the
    /// live tenant is what kept it from being found.
    ///
    /// It is a free-text body that reaches a human: the lead becomes an
    /// email to an operator. So it carries what that operator needs to
    /// answer — which field, how large, and what the satellite said.
    let message: String

    /// Optional. Sent when known, because a lead names a parcel and an
    /// operator thinks in locations.
    let locationId: String?

    /// The reading AT ASK TIME, for the sales record. Optional server-side.
    /// Sent rather than left out: a quote answered three weeks later
    /// against a canopy that has changed is answered against the wrong
    /// field, and this is the only place that moment is preserved.
    let risk: RiskSnapshot?

    struct RiskSnapshot: Encodable, Sendable {
        /// Max 20 characters server-side — the raw level, not a sentence.
        let overall: String?
        let ndvi: Double?
        let ndmi: Double?
    }

    /// The four inputs the server prices from. Optional: an ask may still be
    /// a message alone, and older builds send exactly that.
    let quote: Quote?

    /// NO PRICE FIELD, and that is not an omission.
    ///
    /// The schema strips a price if one is sent. Only these four values cross
    /// the wire and the server computes from them, which is what makes the
    /// local arithmetic in `InsurancePremium` a preview rather than a quote.
    struct Quote: Encodable, Equatable, Sendable {
        /// The server's `productKey` enum — `InsuranceProduct.rawValue`.
        let productKey: String
        /// DECARES, > 0 and <= 2 000 000 server-side. Decares rather than the
        /// hectares the rest of this app sends: the insurance engine works in
        /// dca and converting twice is how a figure drifts.
        let areaDca: Double
        let sumInsuredCents: Int
        /// 1 to 4.
        let instalments: Int

        /// WHERE THE AREA CAME FROM. Absent means "parcel", which is the
        /// default the server applies, so it is only sent when it is not that.
        ///
        /// `crop-at-location` is not produced by this app yet — it needs
        /// `coveredParcelCount` and a crop-wide selection this form has no
        /// concept of. Sending it without the count is a 400, so the case is
        /// absent rather than half-built.
        let areaScope: String?

        static let scopeParcel = "parcel"
        static let scopeCustom = "custom"
    }
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
