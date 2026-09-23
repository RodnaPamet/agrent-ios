import Foundation

/// The seven categories an item can have.
///
/// A CLOSED enum, taken from the server's own schema rather than inferred.
/// `ParcelOperationSheet` splits products by `category != "FERTILIZER"`
/// because when it was written there was no closed list to filter against
/// — that negation stays, because it is also what the web does and it is
/// still right (13 PESTICIDE, 8 FERTILIZER, 3 AMENDMENT on this tenant, so
/// an allowlist of PESTICIDE would hide three items the farm owns).
///
/// This list is for CREATING, where a value the server rejects is not a
/// near miss but a failed save.
enum ItemCategory: String, CaseIterable, Identifiable, Sendable {
    case pesticide = "PESTICIDE"
    case fertilizer = "FERTILIZER"
    case amendment = "AMENDMENT"
    case seed = "SEED"
    case fuel = "FUEL"
    case harvestedProduce = "HARVESTED_PRODUCE"
    case other = "OTHER"

    var id: String { rawValue }

    var label: String {
        switch self {
        // «Препарат за РЗ», not the expansion. The register's own column
        // heading is «Употребено средство за РЗ», so the abbreviation is
        // the form's vocabulary rather than a truncation of it — and the
        // full phrase clipped to «Препарат за р…телна защита» in a picker
        // row, which is worse than either.
        case .pesticide: "Препарат за РЗ"
        case .fertilizer: "Тор"
        case .amendment: "Почвен подобрител"
        case .seed: "Семена"
        case .fuel: "Гориво"
        case .harvestedProduce: "Прибрана продукция"
        case .other: "Друго"
        }
    }

    /// Does the ДНЕВНИК print this one into a regulated column?
    ///
    /// `PESTICIDE` and `AMENDMENT` land in the ХИМИЧНИ ОБРАБОТКИ table
    /// alongside FERTILIZER, and that table has columns for the trade name,
    /// the active ingredient and the quarantine period. For those three,
    /// leaving the optional fields empty produces a register row that is
    /// filed and incomplete — so the form asks for them rather than
    /// treating them as extras.
    /// Must this app insist on the registration number and quarantine
    /// period before it will save?
    ///
    /// Only `PESTICIDE`. The server accepts both as optional for every
    /// category, and the one unassisted attempt on production produced
    /// `Roubdup` twice with all three regulatory fields null. For a
    /// pesticide those feed columns 4, 8 and 9 of the ХИМИЧНИ ОБРАБОТКИ
    /// table and the earliest-harvest date derived from the quarantine.
    ///
    /// A fertiliser has no ЗЗР registration number. Requiring one would
    /// block a legitimate entry, which is what applying a rule past the
    /// case that justified it looks like.
    var requiresRegistrationDetails: Bool { self == .pesticide }

    var appearsOnTheRegister: Bool {
        switch self {
        case .pesticide, .fertilizer, .amendment: true
        case .seed, .fuel, .harvestedProduce, .other: false
        }
    }
}

/// A new catalogue item.
///
/// ── Create only. Never amend. ──
///
/// The ДНЕВНИК joins `product` LIVE at generation time — it selects `name`,
/// `activeIngredient`, `quarantinePeriodDays` and `pppRegistrationNo` when
/// the PDF is built, not when the spray was recorded. So renaming
/// `Generic MAP 11-52-0` in place would retroactively change what all nine
/// already-filed rows say was applied, silently, on a register kept under
/// чл. 115а ЗЗР.
///
/// `CertSnapshot` freezes the operator's and agronomist's certificate
/// numbers onto a row at completion, because who held which certificate at
/// that moment is the factual record. The product name is NOT in that
/// snapshot. Until it is, the only safe move is to leave the archetypes
/// alone and add beside them — so this app has no amend path at all, which
/// is stronger than having one nobody should use.
struct CreateItem: Encodable, Sendable {
    let name: String
    let category: String
    let defaultUnitId: String
    let activeIngredient: String?
    let pppRegistrationNo: String?
    let quarantinePeriodDays: Int?
}

extension LocationsAPI {
    static func createItem(_ draft: CreateItem) async throws -> InputItem {
        // No `Idempotency-Key`: the route does not read one, and `Item` has
        // an INDEX on (tenantId, name) rather than a unique constraint —
        // `createItem` does no existence check either. So a replay silently
        // creates a SECOND product with the same name, and sprays then
        // split across two rows that look identical on the register.
        //
        // Which is why the form searches before it submits, and why this
        // is never retried automatically.
        try await APIClient.shared.post(
            itemsPath, body: draft, as: InputItem.self, idempotencyKey: UUID().uuidString
        )
    }
}
