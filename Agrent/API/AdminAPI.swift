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
}
