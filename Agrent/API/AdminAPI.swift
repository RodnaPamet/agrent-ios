import Foundation

enum AdminAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/admin" }

    /// A BARE ARRAY, measured — not an envelope, and not paged.
    static var membersPath: String { "\(base)/members" }

    /// The same route with a view parameter. Empty on this tenant, so the
    /// element shape is the members shape by assertion rather than by
    /// observation — noted because that is exactly the assumption that has
    /// cost this app a screen before.
    static var invitesPath: String { "\(base)/members?view=invites" }

    static var farmProfilePath: String { "\(base)/farm-profile" }

    /// NOT under `/members`, which is the thing the roadmap got wrong and
    /// would have cost a 404 on the one action this screen exists for.
    static var invitePath: String { "\(base)/invites" }

    static func deactivatePath(_ membershipID: String) -> String {
        "\(base)/members/\(membershipID)/deactivate"
    }

    static func reactivatePath(_ membershipID: String) -> String {
        "\(base)/members/\(membershipID)/reactivate"
    }

    static func decodeMembers(from data: Data) async throws -> [Membership] {
        try await APIClient.shared.decode(data, as: [Membership].self)
    }

    static func decodeFarmProfile(from data: Data) async throws -> FarmProfile {
        try await APIClient.shared.decode(data, as: FarmProfile.self)
    }

    /// Whether a refusal is "you are not allowed here" rather than a fault.
    ///
    /// These routes use `requirePermission('admin.members')`, so a READER
    /// gets a 403 — and that is a REAL STATE with real accounts behind it,
    /// not an error. An empty list would read as "this farm has no
    /// members", which is a false statement about the farm rather than a
    /// true one about the reader.
    static func isForbidden(_ error: Error) -> Bool {
        guard case APIClient.APIError.http(let status, _, _) = error else { return false }
        return status == 403
    }

    // MARK: - Writes

    /// Invite somebody. `{ email, role }` — nothing else.
    ///
    /// ── SAFE TO RETRY, and the reason is a natural key rather than a
    ///    header ──
    ///
    /// The route honours no `Idempotency-Key`, but there is a
    /// `@@unique([tenantId, email])` and the usecase writes THROUGH it:
    /// re-inviting an address with a pending invite UPSERTS rather than
    /// erroring or creating a second. So a replay produces one row and the
    /// only cost is a second email to a colleague.
    ///
    /// That is stronger than a header, because it holds against a client
    /// that never sends one — the same argument `createInquiry` makes from
    /// its own unique constraint.
    ///
    /// An address that is ALREADY an active member is a 400 with English
    /// prose and the generic code, so it surfaces through the status
    /// sentence rather than as itself. Worth knowing when the message on
    /// screen is vaguer than the situation.
    static func invite(email: String, role: MembershipRole) async throws -> Data {
        try await APIClient.shared.postReturningData(
            invitePath,
            body: Invite(email: email, role: role.rawValue),
            idempotencyKey: nil
        )
    }

    private struct Invite: Encodable { let email: String; let role: String }

    /// Deactivate or reactivate. **NO BODY** — the membership id in the
    /// path is the whole request.
    ///
    /// ── DO NOT RETRY, and the reason is sharper than "it is a write" ──
    ///
    /// The lookup filters `status: 'ACTIVE'`. So once the first call
    /// succeeds the row no longer matches, and a replay returns **404
    /// "Membership not found or not active"** — a SUCCESSFUL WRITE WHOSE
    /// RETRY REPORTS FAILURE.
    ///
    /// That is the already-applied problem wearing a 404 instead of a 400,
    /// and it is exactly the #921 shape: the operator is told their action
    /// did not land when it already has. `setTaskStatus` solved it
    /// server-side by comparing state; this route has not, and is
    /// documented rather than fixed.
    ///
    /// So a timeout here is never re-sent. The caller RE-READS the member
    /// list, which is the authority on whether it landed — the list can
    /// answer the question the retry cannot.
    static func setActive(_ membershipID: String, active: Bool) async throws -> Data {
        try await APIClient.shared.postReturningData(
            active ? reactivatePath(membershipID) : deactivatePath(membershipID),
            body: EmptyBody(),
            idempotencyKey: nil
        )
    }

    private struct EmptyBody: Encodable {}
}
