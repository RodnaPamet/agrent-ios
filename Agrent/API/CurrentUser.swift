import Foundation

/// Who is signed in.
///
/// ── Why this exists, and what it closes ──
///
/// The app knew its TOKENS and not its USER. That cost two things:
/// `assigneeUserId` on a field operation, which is `z.string().min(1)` —
/// required, not nullable — and the self-deactivation guard on the admin
/// screen, which had to fall back to the server's 403 after the tap.
///
/// Both were solvable only by reading the access token's claims, and
/// guessing which claim carries an id is exactly the kind of inference
/// this codebase has been bitten by repeatedly. `GET /api/auth/me` makes
/// the guess unnecessary.
///
/// ── `tenant` IS DELIBERATELY NOT MODELLED ──
///
/// The response carries `{ user, tenant }` and the tenant block is a trap:
/// it comes from `tenantMemberships` ordered `createdAt asc, take 1` — the
/// user's OLDEST membership, not the one they are currently looking at.
/// For a single-tenant user those coincide; for anyone else they do not,
/// and code that reached for `me.tenant.slug` to decide which farm it was
/// in would be right until the first person joined a second one.
///
/// Leaving it out is stronger than a comment saying not to use it. The
/// field this app needs is `user.id`, which is always correct. The tenant
/// comes from `Config.tenantSlug`, as it always has.
///
/// ── The path carries no tenant slug ──
///
/// So it sits outside the operator lockdown and a MECHANISATOR can call
/// it — which matters, because that persona is blocked from
/// `/users/assignable` and self-assignment is the only assignment they
/// can express.
struct CurrentUser: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let email: String?

    /// The role on the user's OLDEST membership — same caveat as the
    /// tenant block, and it is NOT a permission decision. It is used only
    /// to decide whether to OFFER an affordance.
    let role: String?

    /// The saved bottom-row order, or nil when never chosen.
    ///
    /// nil and `[]` are DIFFERENT and the column is nullable to keep them
    /// so: "never chose" draws the default, "deliberately cleared" does
    /// not. Collapsing them is unrecoverable.
    ///
    /// Read from BOTH the `user` object and the envelope root, because at
    /// the time this was written the field had not deployed and the probe
    /// could only show where it was NOT:
    ///
    ///     {"user":{"id":…,"email":…,"name":…,"role":"OWNER"},
    ///      "tenant":{…}}
    ///
    /// Guessing one location and being wrong would not fail — it would
    /// decode nil forever, and the feature would look like a save that
    /// never persists. Accepting both costs four lines and cannot be
    /// wrong in that particular silent way.
    let bottomTabOrder: [String]?

    private enum Outer: String, CodingKey { case user, bottomTabOrder }
    private enum Inner: String, CodingKey { case id, name, email, role, bottomTabOrder }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let user = try outer.nestedContainer(keyedBy: Inner.self, forKey: .user)
        self.id = try user.decode(String.self, forKey: .id)
        self.name = try user.decodeIfPresent(String.self, forKey: .name)
        self.email = try user.decodeIfPresent(String.self, forKey: .email)
        self.role = try user.decodeIfPresent(String.self, forKey: .role)
        self.bottomTabOrder =
            (try? user.decodeIfPresent([String].self, forKey: .bottomTabOrder))
            ?? (try? outer.decodeIfPresent([String].self, forKey: .bottomTabOrder))
            ?? nil
    }

    /// May this person create a field operation?
    ///
    /// ── This gates an AFFORDANCE, never an action ──
    ///
    /// The server decides: `createFieldOperation` calls `assertCanWrite`,
    /// and `canWrite` is `ROLE_ORDER >= 3`. MECHANISATOR is 1, so an
    /// operator cannot create one — their job is COMPLETION, not creation
    /// (`/my-work`, marking assigned parcels done). The path allowlist
    /// letting `/locations/:id/operations` through is not the same as the
    /// write succeeding; there are two gates and this is the second.
    ///
    /// ── FAILS OPEN, deliberately ──
    ///
    /// `role` comes from the OLDEST membership, so for anyone in two
    /// tenants it may not be their role HERE. An unrecognised or absent
    /// role therefore shows the control and lets the server refuse.
    ///
    /// Hiding a button from somebody who could have used it is worse than
    /// showing one that might be refused: the refusal is a sentence they
    /// can read and report, the absence is a feature they conclude does
    /// not exist. The server is the authority either way, and its refusal
    /// is rendered.
    var mayCreateOperations: Bool {
        switch role?.uppercased() {
        case "MECHANISATOR", "READER", "AUDITOR": false
        default: true
        }
    }

    init(id: String, name: String?, email: String?, role: String?,
         bottomTabOrder: [String]? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.bottomTabOrder = bottomTabOrder
    }
}

enum MeAPI {
    /// No tenant slug in the path, deliberately — see `CurrentUser`.
    static let path = "/api/auth/me"

    static func decode(from data: Data) async throws -> CurrentUser {
        try await APIClient.shared.decode(data, as: CurrentUser.self)
    }
}

/// Cached for the session, because identity does not change under an
/// operator mid-spray.
///
/// NOT through `ResponseCache`: that writes raw bytes to disk, and this
/// response is the operator's own name and email. It is one call per
/// launch and is held in memory only — the same reasoning that keeps the
/// members list off the disk.
@Observable
@MainActor
final class CurrentUserStore {
    static let shared = CurrentUserStore()

    private(set) var user: CurrentUser?
    private var inFlight: Task<CurrentUser?, Never>?

    func load() async -> CurrentUser? {
        if let user { return user }
        if let inFlight { return await inFlight.value }

        let task = Task<CurrentUser?, Never> {
            defer { inFlight = nil }
            do {
                let data = try await APIClient.shared.data(for: MeAPI.path)
                let me = try await MeAPI.decode(from: data)
                user = me
                return me
            } catch {
                Log.auth.error("could not resolve current user: \(Log.summary(for: error), privacy: .public)")
                return nil
            }
        }
        inFlight = task
        return await task.value
    }

    func clear() { user = nil }
}
