import Foundation

/// A membership, as `/admin/members` sends it — MEASURED 2026-09-22 by
/// reading the route, not the Prisma model.
///
/// Nineteen keys. Most are nulls this screen has no use for
/// (`agronomistCertNo`, `applicatorCertNo`, `customRole`, `customRoleId`,
/// `provisionedByOrgId`) and are left unmodelled: an absent property costs
/// nothing, and a wrongly-typed one fails the whole list.
struct Membership: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let userId: String
    let role: MembershipRole
    let status: MembershipStatus
    let user: Person

    /// `{ id, name }` — note NO email, where `user` has one. Two
    /// projections of the same model with different fields; the same
    /// asymmetry that turned out to be a PII allowlist gap on the
    /// locations route, so it is modelled as measured rather than assumed
    /// symmetric.
    let invitedBy: Brief?
    let invitedAt: Date?
    let deactivatedAt: Date?

    /// How many sessions this person currently has open. The one number on
    /// the screen that answers "is this account actually being used", which
    /// is the question behind most deactivations.
    let activeSessionCount: Int?

    let createdAt: Date
    let updatedAt: Date

    /// A colleague. PERSONAL DATA — displayable, and never a log line, a
    /// query parameter or a cache key. `image` is a URL this app does not
    /// render; it is modelled only so its absence is not mistaken for a
    /// decode problem later.
    struct Person: Decodable, Equatable, Sendable {
        let id: String
        let name: String?
        let email: String?
        let image: String?

        /// Falls back to the address, then to nothing. An empty cell beats
        /// the word "Unknown" in English on a Bulgarian screen.
        ///
        /// Guarded against ciphertext for the same reason `WorkItemSummary`
        /// is: the task detail route returned a `createdBy.name` of
        /// `v1:FTDt/…` because a PII allowlist had missed that relation,
        /// and a ciphertext must never reach a person whatever the reason
        /// it arrived.
        var displayName: String? {
            WorkItemSummary.Assignee(id: id, name: name, email: email).displayName
        }
    }

    struct Brief: Decodable, Equatable, Sendable {
        let id: String
        let name: String?
    }
}

/// THREE statuses, and a two-state control cannot express them.
///
/// "Has my invite actually gone out?" is the main reason somebody opens
/// this screen, and an INVITED member rendered as either of the other two
/// answers it wrongly.
enum MembershipStatus: String, LenientDecodable, Sendable {
    case active = "ACTIVE"
    case invited = "INVITED"
    case deactivated = "DEACTIVATED"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .active: "Активен"
        case .invited: "Поканен"
        case .deactivated: "Деактивиран"
        case .unknown: "—"
        }
    }
}

/// Roles.
///
/// PROVISIONAL, and marked so rather than presented as complete. This
/// tenant returns only `ADMIN` and `OWNER` — two values out of an enum
/// whose size nobody here has counted, which is precisely the
/// `LogEntryType` situation: six cases shipped against the server's ten,
/// surviving only because the live tenant happened to hold two of them.
///
/// `LenientDecodable` means an unrecognised role costs a label on one row
/// rather than the list, and `label` falls through to the RAW VALUE so an
/// unknown role reads as `MECHANISATOR` rather than as a dash. Ugly and
/// legible beats tidy and absent.
///
/// The Bulgarian is requested from `bg.json` and is NOT written here —
/// inventing a vocabulary is a mistake this codebase has now made once and
/// caught twice.
enum MembershipRole: String, LenientDecodable, Sendable {
    case owner = "OWNER"
    case admin = "ADMIN"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .owner: "Собственик"
        case .admin: "Администратор"
        case .unknown: "—"
        }
    }
}

/// The БАБХ identity block. Ten fields, all null on this tenant.
///
/// ── `egn` IS A NATIONAL IDENTITY NUMBER ──
///
/// The most sensitive single field this app has modelled. Three things
/// follow, and none is optional:
///
/// 1. Never a log line, a query parameter or a cache key. The existing
///    rule, with the stakes raised.
/// 2. Displayed MASKED, with an explicit reveal — see `FarmProfileView`.
/// 3. It is in the response body, so `ResponseCache` writes it to disk
///    like everything else. Not modelling it would not prevent that; the
///    cache stores bytes. That is worth knowing rather than assuming the
///    Swift is the boundary.
struct FarmProfile: Decodable, Equatable, Sendable {
    let producerName: String?
    let eik: String?
    let egn: String?
    let address: String?
    let settlement: String?
    let municipality: String?
    let registrationPlace: String?
    let registrationEkatte: String?
    let odbhCity: String?
    let agricultureDirectorateCity: String?

    /// Nothing filled in at all, which is the state this tenant is in and
    /// needs saying rather than showing ten empty rows.
    var isEmpty: Bool {
        [producerName, eik, egn, address, settlement, municipality,
         registrationPlace, registrationEkatte, odbhCity,
         agricultureDirectorateCity]
            .allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
