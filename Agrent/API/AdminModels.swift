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

/// FOUR statuses. PARITY.md recorded three and this tenant shows one.
///
/// `REMOVED` was the missing one, and the only place the full set was
/// written down outside the Prisma schema was the web's own status-variant
/// map. Modelled from that rather than from the two a live tenant happened
/// to hold — which is the `LogEntryType` lesson applied before it bit
/// rather than after.
///
/// "Has my invite actually gone out?" is the main reason somebody opens
/// this screen, so INVITED rendered as either of the others answers it
/// wrongly.
enum MembershipStatus: String, LenientDecodable, Sendable {
    case invited = "INVITED"
    case active = "ACTIVE"
    case deactivated = "DEACTIVATED"
    case removed = "REMOVED"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    /// `authEnums.membershipStatus.*`, verbatim.
    var label: String {
        switch self {
        case .invited: "Поканен"
        case .active: "Активен"
        case .deactivated: "Деактивиран"
        case .removed: "Премахнат"
        case .unknown: "—"
        }
    }
}

/// SIX roles. This tenant returns two.
///
/// Exactly the `LogEntryType` shape — six cases shipped against the
/// server's ten, surviving only because the live tenant happened to hold
/// two of them — so these were counted against the schema rather than
/// collected from a payload.
///
/// `MECHANISATOR` is the one to get right if this screen ever filters by
/// role: it is the restricted machine-operator persona, confined by
/// middleware to a short allowlist, never SSO-mappable, and a `switch`
/// that omits it silently inherits READER's "view everything".
///
/// ── The Bulgarian did not exist, on either client ──
///
/// `messages/` held three crop vocabularies and NONE for the role a person
/// holds: the web rendered `{m.role}` and `{row.original.status}` raw, so a
/// Bulgarian admin has been reading "OWNER" and "ACTIVE" on an otherwise
/// fully translated screen — the same defect as the calculator's "wheat",
/// on a different screen, found by asking the same question.
///
/// So this was not a fourth vocabulary waiting to happen; it was the
/// FIRST, and had I written it here the server would have written a second
/// an hour later. It is canonical now at `authEnums.role.*` with a guard
/// deriving the required members from the schema, and these are verbatim.
enum MembershipRole: String, LenientDecodable, Sendable {
    case owner = "OWNER"
    case admin = "ADMIN"
    case editor = "EDITOR"
    case reader = "READER"
    case auditor = "AUDITOR"
    case mechanisator = "MECHANISATOR"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    var label: String {
        switch self {
        case .owner: "Собственик"
        case .admin: "Администратор"
        case .editor: "Редактор"
        case .reader: "Читател"
        case .auditor: "Одитор"
        case .mechanisator: "Механизатор"
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

    // ── The holding, added 2026-09-27 with agri-saas#1141/#1145 ──
    //
    // The ten above describe the PRODUCER — who they are and where they are
    // registered. These three describe the HOLDING.

    /// УРН, the holding's registration number. `["string","null"]`.
    ///
    /// A state identifier, encrypted at rest server-side and arriving as
    /// PLAINTEXT like `egn` and `eik` — so the rules in this file's header
    /// apply to it in full: never a log line, a query parameter or a cache
    /// key. It is NOT masked on screen: the owner's ruling is that ЕИК and
    /// УРН are business identifiers appearing on public filings, while ЕГН is
    /// the personal one and keeps its reveal.
    let urn: String?

    /// Declared hectares. A NUMBER, and this is where the pattern in this
    /// repo misleads.
    ///
    /// `quantityTonnes` on the exchange is a decimal STRING, `WireDecimal`
    /// exists to accept either, and the habit those built is "server decimals
    /// are strings". That habit came from MONEY, where a binary float cannot
    /// represent a cent and a rounding error is someone's lev. An area in
    /// hectares to three decimals is exactly representable, and the contract
    /// says `["number","null"]`, so a `Double?` is what it is.
    ///
    /// NULL AND ZERO ARE DIFFERENT CLAIMS. Null is "not declared"; 0 is a
    /// declaration of zero hectares. Collapsing them would show a farm that
    /// declared nothing and a farm that declared zero as the same thing, and
    /// only one of those is a farm that has told the state something.
    let sizeHa: Double?

    /// Declared crops. `[]` when unset, NEVER null, and in `required`.
    ///
    /// NOT OPTIONAL, which breaks the shape of every field above it. All ten
    /// of those are `String?`; this one is always present, so an optional here
    /// would model a state the server cannot produce — and the empty case is
    /// `[]`, not `nil`, which is why it cannot join `isEmpty`'s array below.
    let grainProduced: [String]

    /// The optimistic-lock version (agri-saas#1184). Sent back as `If-Match`
    /// on the save, so a write made over a profile someone else has since
    /// changed is a 409 rather than a silent overwrite.
    ///
    /// `0` IS A SENTINEL, not a version: GET answers an all-null body for a
    /// tenant with no row, and reports 0 for it. No stored row ever carries 0
    /// (the column defaults to 1), so `If-Match: 0` means exactly "create" —
    /// and fails with a 409 if someone created the row first.
    ///
    /// OPTIONAL although the spec puts it in `required`. That is the safe
    /// direction `DecoderToleranceTests` asks for: a server rolled back to
    /// before #1184 omits it, and a non-optional would turn the whole profile
    /// screen into an error over a field nobody reads on screen. nil means
    /// "the server offered no lock" and the save goes UNGUARDED, which is
    /// exactly what the server documents for an absent header — never a
    /// guessed 0, which would be a create attempt over an existing row.
    ///
    /// `var` with a default so the memberwise init — the all-null stand-in
    /// for a 403 and every test fixture — need not mention it.
    var version: Int? = nil

    /// Nothing filled in at all, which is the state this tenant is in and
    /// needs saying rather than showing thirteen empty rows.
    ///
    /// THE THREE NEW FIELDS HAD TO BE ADDED HERE TOO, and the reason is not
    /// symmetry. The plausible near-term state is a tenant who fills exactly
    /// `urn`, `sizeHa` and `grainProduced` and nothing else — those are the
    /// three that just arrived. Left out, this would report "nothing filled
    /// in" over three populated rows, and it would fail in the direction that
    /// looks like an empty database rather than like a bug.
    ///
    /// `sizeHa` and `grainProduced` cannot join the array — one is a `Double?`
    /// and the other is never nil — so they are tested on their own terms.
    /// `sizeHa != nil` rather than `sizeHa != 0`, because a declared zero is
    /// still a declaration.
    var isEmpty: Bool {
        let noText = [producerName, eik, egn, urn, address, settlement,
                      municipality, registrationPlace, registrationEkatte,
                      odbhCity, agricultureDirectorateCity]
            .allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        return noText && sizeHa == nil && grainProduced.isEmpty
    }
}
