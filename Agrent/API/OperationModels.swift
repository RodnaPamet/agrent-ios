import Foundation

/// A catalogued input — a product, a fertiliser, an amendment.
///
/// `/items` returns RAW ROWS, not a lean DTO: 18 keys including
/// `activeIngredient`, `pppRegistrationNo`, `quarantinePeriodDays`, `sku`
/// and the soft-delete columns. Only what this sheet uses is modelled;
/// an absent property costs nothing and a wrongly-typed one fails the
/// whole list.
struct InputItem: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let category: String
    let defaultUnit: Unit?

    /// Who created this row. **nil means the seeder did.**
    ///
    /// Verified on the wire rather than taken from the schema: the key is
    /// present on 24 of 24 rows, and `createdByUserId IS NULL`,
    /// `attributesJson IS NOT NULL` and `name LIKE 'Generic %'` partition
    /// the catalogue IDENTICALLY — 22 archetypes, 2 user-created. Three
    /// signals agreeing is what makes this a fact rather than one of them
    /// being a guess that happens to work.
    let createdByUserId: String?

    /// ── THE SPLIT IS A NEGATION, NOT AN ALLOWLIST ──
    ///
    ///     FERTILIZER → category == "FERTILIZER"
    ///     PRODUCT    → category != "FERTILIZER"    ← everything else
    ///
    /// Measured on this tenant: 24 items — 13 PESTICIDE, 8 FERTILIZER,
    /// **3 AMENDMENT**. So filtering products to `PESTICIDE` would hide
    /// three items the farm has catalogued, and an operator would find the
    /// app simply does not list something they own. The negation is what
    /// the web does and it is right; a test pins the count so nobody
    /// "tidies" it into an allowlist.
    var isFertilizer: Bool { category.uppercased() == "FERTILIZER" }

    /// A seeded placeholder rather than a real product.
    ///
    /// 22 of this tenant's 24 items are archetypes: deliberate, because a
    /// proprietary label database is a licensing problem, and meant to be
    /// replaced. Nothing marks them as provisional on the register they
    /// are printed onto.
    ///
    /// Keyed on `createdByUserId`, NOT on the name. The name prefix
    /// partitions the catalogue identically today, and it is still the
    /// weaker signal — it is a string heuristic where the other is a
    /// column. A real product called "Generic Glyphosate 360" would be
    /// flagged by one and not the other, and the one that gets it right
    /// is the one that asks who made the row.
    ///
    /// If the key ever vanishes from the payload this flags EVERYTHING as
    /// an archetype, which is the safer direction to fail in: a warning on
    /// every product is noticed and fixed, a warning on none is not.
    var isArchetype: Bool { createdByUserId == nil }
}

/// A unit of measure.
///
/// `?measure=RATE` is NOT optional on the units call — 4 against 20, and
/// the 20 include `kg`, `ha`, `t` and `%`, none of which is a dose rate.
/// The four are already Bulgarian: г/дка, кг/дка, л/дка, мл/дка.
struct Unit: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let key: String

    /// OPTIONAL, because `/items` does not send it.
    ///
    /// ── This broke the product picker completely ──
    ///
    /// Two endpoints return a unit and they return DIFFERENT SHAPES:
    ///
    ///     /units        id, key, name, symbol, measure
    ///     /items[].defaultUnit   id, key, symbol, measure      ← no name
    ///
    /// Measured on production, 24 of 24 rows. With `name` non-optional the
    /// nested object threw, and because `defaultUnit: Unit?` is an optional
    /// PROPERTY rather than a lenient decode, the throw propagated and took
    /// the whole array with it:
    ///
    ///     DecodingError.keyNotFound: Key 'name' not found.
    ///     Path: [0].defaultUnit
    ///
    /// So `/items` returned 17KB and produced zero products. The spray
    /// sheet's picker renders `ProgressView()` while `items.value == nil`,
    /// which a decode failure also satisfies — so it span forever rather
    /// than saying anything.
    ///
    /// Same lesson as `WireDecimal`: a shape is a property of an ENDPOINT,
    /// not of a type. The same lesson as `notes` being HTML, too — a field
    /// is not known until a screen displays it, and this one had never
    /// been decoded by anything that was watched.
    let name: String?

    let symbol: String
    let measure: String?

    /// What to show. `symbol` is present on both shapes, so this never
    /// falls through to an id — and when the name IS present it is not
    /// repeated as its own parenthetical.
    var pickerLabel: String {
        guard let name, !name.isEmpty, name != symbol else { return symbol }
        return "\(name) (\(symbol))"
    }
}

/// How the input is applied.
///
/// ── FREE TEXT, AND THE SERVER DOES NOT VALIDATE IT ──
///
/// The column is `String?` and the schema is
/// `z.string().max(255).nullable().optional()`. The seven below are a UI
/// array on the web, not an enum, and **production already holds values
/// outside them**: measured on this tenant, `Dron` and `dron` — two
/// casings of a value that is not even the slug, which is `drone`.
///
/// So this is `cropType` again: a case-folding lookup with PASSTHROUGH. A
/// `switch` over the seven would render nothing at all for both existing
/// rows.
///
/// ── AND IT IS PRINTED RAW ONTO A LEGAL DOCUMENT ──
///
/// `applicationTechnique` is the "Техника за приложение" field on the
/// ДНЕВНИК, the БАБХ register, and the generator prints it verbatim —
/// `l.applicationTechnique ?? ''`, no lookup, no localisation.
///
/// Therefore this sheet WRITES THE SLUG (`drone`), never the label
/// (`Дрон`). Writing the label would put Bulgarian in a slug column and
/// onto a filed document in a format nothing else uses; writing `Dron`
/// would reproduce the mess already there. The slug is what the web
/// writes and what the register expects.
enum ApplicationTechnique: String, CaseIterable, Identifiable, Sendable {
    case boom, ground, airblast, knapsack, spreader, drone, other

    var id: String { rawValue }

    /// `ag.map.parcelSheet.techniqueOptions.*`, verbatim.
    var label: String {
        switch self {
        case .boom: "Щангова пръскачка"
        case .ground: "Наземна пръскачка"
        case .airblast: "Вентилаторна пръскачка"
        case .knapsack: "Гръбна пръскачка"
        case .spreader: "Разпръсквач на тор"
        case .drone: "Дрон"
        case .other: "Друго"
        }
    }

    /// Bulgarian for a stored value, falling back to the value itself.
    ///
    /// Folds case, so the `Dron` and `dron` already in production both
    /// resolve — and anything else shows as written rather than as
    /// nothing.
    static func display(_ stored: String?) -> String? {
        guard let stored else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return allCases.first { $0.rawValue == trimmed.lowercased() }?.label ?? trimmed
    }
}

/// What the sheet posts.
///
/// ── PRODUCT XOR FERTILISER ──
///
/// The usecase refuses both or neither — `OPERATION_INPUT_AMBIGUOUS`,
/// with `PRODUCT_DOSE_REQUIRED` and `FERTILIZER_DOSE_REQUIRED` beside it.
/// Mirrored here so an operator learns before the request.
///
/// ── AND THIS ONE IS GENUINELY IDEMPOTENT ──
///
/// `field-operation` honours `Idempotency-Key`, so a retry here is SAFE
/// and the outbox may replay it. Unlike the exchange listing and the
/// deactivation, which honour no key and must never be queued.
///
/// NOT unlike the cost row any more: `POST /grain/costs` honours the header
/// too and has sent a key since 2026-09-25 (see `CostIdempotencyKey`). The
/// difference left is that this write has a QUEUE behind it — a key minted
/// once and held across attempts, replayed by `OutboxStore` — whereas the
/// cost sheet mints a key per draft and never replays anything. Safe to
/// retry is a property of the route; actually retrying is a separate
/// decision, and only this write has had it made.
struct CreateFieldOperation: Encodable, Sendable {
    let operationType: String
    let parcelIds: [String]
    let assigneeUserId: String?

    let productItemId: String?
    let doseValue: Decimal?
    let doseUnitId: String?
    let waterRateValue: Decimal?
    let waterRateUnitId: String?

    let fertilizerItemId: String?
    let fertilizerDoseValue: Decimal?
    let fertilizerDoseUnitId: String?

    /// The SLUG. See `ApplicationTechnique`.
    let applicationTechnique: String?
    let targetNote: String?

    enum Invalid: Equatable {
        case noParcel
        case inputAmbiguous
        case inputMissing
        case doseMissing
        case doseNotPositive
    }

    var problems: [Invalid] {
        var found: [Invalid] = []
        if parcelIds.isEmpty { found.append(.noParcel) }

        let hasProduct = productItemId != nil
        let hasFertilizer = fertilizerItemId != nil
        if hasProduct && hasFertilizer { found.append(.inputAmbiguous) }
        if !hasProduct && !hasFertilizer { found.append(.inputMissing) }

        if hasProduct {
            if doseValue == nil || doseUnitId == nil { found.append(.doseMissing) }
            else if let d = doseValue, d <= 0 { found.append(.doseNotPositive) }
        }
        if hasFertilizer {
            if fertilizerDoseValue == nil || fertilizerDoseUnitId == nil {
                found.append(.doseMissing)
            } else if let d = fertilizerDoseValue, d <= 0 {
                found.append(.doseNotPositive)
            }
        }
        return found
    }
}
