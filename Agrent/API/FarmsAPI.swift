import Foundation

/// A person's farms, outside any one farm (agrent-ios#179): listing them,
/// creating one, and checking an ЕИК on the way.
///
/// NO TENANT SLUG in any path. A person with no farm has no tenant to put
/// there, and adding a farm is something a person does, not a farm.
enum FarmsAPI {
    /// `GET` lists the caller's farms (agri-saas#1396); `POST` creates one.
    ///
    /// ── The GET is UNGATED, unlike the POST ──
    ///
    /// `social.farm-registration` decides whether a person may ADD a farm,
    /// never whether they can reach the ones they already belong to — asked
    /// for by this app and agreed, and the spec says it in as many words. So
    /// the list is read whatever the flag says.
    static let farmsPath = "/api/me/farms"

    /// One row of `GET /api/me/farms`: a farm the caller is an ACTIVE member
    /// of. The spec also sends the farm's `id`, which nothing here reads.
    ///
    /// ── No row is ever dropped, unlike most lists here ──
    ///
    /// Elsewhere one bad row costs that row (a lossy array). Here a dropped
    /// row would read as "no longer yours", and `FarmStore` CLOSES a farm
    /// that is absent from this list. So a row this build cannot read fails
    /// the whole list — a plain array — and a list that fails changes nothing.
    struct Membership: Decodable, Equatable, Sendable {
        /// "Use this for navigation. Server-generated and stable."
        let slug: String
        let name: String
        /// The caller's role IN THAT FARM. A growing union, so a string.
        let role: String
    }

    /// The envelope. `farms[0]` is the OLDEST membership — the same farm
    /// `/api/auth/me` names — and the spec calls that order a contract. An
    /// empty array, never a 404, for a person with no farm.
    struct Farms: Decodable, Equatable, Sendable {
        let farms: [Membership]
    }

    static func decodeFarms(from data: Data) async throws -> [Membership] {
        try await APIClient.shared.decode(data, as: Farms.self).farms
    }

    /// NETWORK ONLY, never `ResponseCache`. What the list decides — which
    /// farm stays open, the role each screen gates on — must come from the
    /// server as it is NOW: a cached copy from before a farm was created
    /// would close it, and one from before a removal would keep a dead farm
    /// open. Offline, the open farm and its remembered role carry on.
    static func farms() async throws -> [Membership] {
        try await decodeFarms(from: APIClient.shared.data(for: farmsPath))
    }

    /// POST, never GET with a query. Anything typed here may be an ЕГН —
    /// spotting one is what the route is for — and a query string is logged
    /// by CFNetwork with the URL, unsuppressably (agri-saas, backend 1).
    static let eikCheckPath = "/api/public/eik-check"

    /// `CreateFarmRequest`. `eik` is OMITTED, not null, for «Земеделски
    /// стопанин — физическо лице»: the contract reads absence as that, and the
    /// synthesised encoder leaves a nil optional out.
    struct CreateFarm: Encodable, Equatable, Sendable {
        let name: String
        let eik: String?
    }

    /// `CreateFarmResponse`.
    struct Created: Decodable, Equatable, Sendable {
        struct Farm: Decodable, Equatable, Sendable {
            let id: String
            /// SERVER-GENERATED, with a uniqueness suffix — read it from here,
            /// never derive it from the name: two farms of one name differ.
            let slug: String
            let name: String
        }
        let farm: Farm
        let identityVerification: IdentityVerification
    }

    /// What became of the ЕИК. NEVER read as acceptance: `pendingReview` is
    /// the answer for a free ЕИК AND for one another farm already holds, by
    /// design — anything else would tell a stranger whether a farm is in
    /// Agrent. The real state is the farm profile's derived `eikVerification`.
    enum IdentityVerification: String, LenientDecodable, Sendable {
        case notRequested = "not_requested"
        case pendingReview = "pending_review"
        /// The farm exists; the ЕИК could not be recorded and can be added
        /// from the farm's settings. Nothing the farmer did was wrong.
        case deferred
        case unknown

        static var unknownCase: Self { .unknown }
    }

    /// What the register says about the digits typed so far.
    struct EikVerdict: Decodable, Equatable, Sendable {
        let valid: Bool
        /// Looks like a PERSONAL identity number — stop, do not continue.
        let looksLikeEgn: Bool
        /// The farm's name in the register, when it could be read; it
        /// prefills the name step.
        let registryName: String?
    }

    /// Creates a REAL farm. Under the UI-test seam every write is a 501 that
    /// never leaves the process; nothing in development or CI calls this —
    /// the first one is the owner's.
    static func create(_ farm: CreateFarm) async throws -> Created {
        try await APIClient.shared.post(farmsPath, body: farm, as: Created.self)
    }

    static func checkEik(_ eik: String) async throws -> EikVerdict {
        struct Body: Encodable { let eik: String }
        return try await APIClient.shared.post(eikCheckPath, body: Body(eik: eik), as: EikVerdict.self)
    }
}
