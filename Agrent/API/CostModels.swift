import Foundation

/// A cost entry as it comes BACK, measured against production on
/// 2026-09-22 by creating one and reading the response.
///
/// ── Three asymmetries on one round trip ──
///
/// 1. **`amount` goes out as a number and comes back as a number.** Both
///    usecases map through `toDto`, which converts the `Decimal` column.
///    That is NOT the rule for the whole API — `ExchangeListing`
///    `quantityTonnes` has no DTO and is a string. See `WireDecimal`.
/// 2. **`incurredOn` goes out as `"2026-09-22"` and comes back as
///    `"2026-09-22T00:00:00.000Z"`.** A `min(8)` string on the way in, a
///    full ISO timestamp on the way out — so it is a `String` to send and
///    a `Date` to read, on one field.
/// 3. **The LIST omits `description`.** 25 keys on a create, 24 on a list
///    row, and `description` is the difference. Modelled optional, which
///    it has to be anyway, but worth knowing before a detail screen goes
///    looking for it in a list row.
///
/// The relation OBJECTS — `invoiceFile`, `item`, `location`, `parcel`,
/// `planting`, `season` — are present and were all null on the only row
/// observed. The spec documents their shapes now (agrent-ios#182); they stay
/// unmodelled because no screen reads them, and a modelled field nothing
/// reads is only a way for the list to fail. Their `*Id` siblings are
/// modelled, because a string id has no shape to get wrong.
struct CostEntry: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let category: CostCategory
    let amount: WireDecimal
    let currency: String

    /// Full ISO on the way back, unlike the date-only string sent to
    /// create it.
    let incurredOn: Date

    let supplier: String?

    /// ABSENT from the list projection. Present on a create response.
    let description: String?

    let allocationBasis: String?
    let seasonId: String?
    let plantingId: String?
    let locationId: String?
    let parcelId: String?
    let leaseId: String?
    let itemId: String?
    let invoiceFileId: String?
    let createdAt: Date
    let updatedAt: Date

    /// `Decimal(14,2)` — the scale display must pad back to, because `1.00`
    /// arrives as `1`.
    static let amountScale = 2

    var amountText: String { amount.text(scale: Self.amountScale) }
}

/// `{ rows, totalCount, truncated }` — the FIFTH envelope variant in this
/// API. `totalCount` is read here rather than dropped: it is the only
/// honest answer to "did my cost save?" when the list is capped.
struct CostPage: Equatable, Sendable {
    let items: [CostEntry]
    let totalCount: Int?
    let truncated: Bool
}

/// A cost entry — a line on a farm's books.
///
/// ── The eight categories ──
///
/// Bulgarian taken from `messages/bg.json` `grainEnums.costCategory`, and
/// NOT from `inventory.itemCategory`, which spells overlapping names
/// differently: FERTILIZER is "Торове" in the grain vocabulary and "Тор" in
/// the inventory one. Two vocabularies for one code is the same trap as
/// `taskEnums.status` versus `agStatus.operation`, and the answer is the
/// same — the screen takes the vocabulary of the thing it is showing.
enum CostCategory: String, LenientDecodable, Sendable {
    case payroll = "PAYROLL"
    case rent = "RENT"
    case fertilizer = "FERTILIZER"
    case fuel = "FUEL"
    case seed = "SEED"
    case pesticide = "PESTICIDE"
    case service = "SERVICE"
    /// Interest and fees on the farm's credit, and the machines' amortisation —
    /// the two overheads the owner's «Режийни» sheet added (#245, agri-saas
    /// #1511), in the web's words (`grainEnums.costCategory`).
    case credit = "CREDIT"
    case depreciation = "DEPRECIATION"
    case other = "OTHER"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    /// The ten a person may CHOOSE. `unknown` is this client's own
    /// sentinel for a category the server added and this build has not
    /// heard of — it can arrive, but it must never be offered.
    static var selectable: [CostCategory] {
        allCases.filter { $0 != .unknown }
    }

    var label: String {
        switch self {
        case .payroll: "Заплати"
        case .rent: "Ренда"
        case .fertilizer: "Торове"
        case .fuel: "Горива"
        case .seed: "Семена"
        case .pesticide: "Препарати"
        case .service: "Услуги"
        case .credit: "Кредитни разходи"
        case .depreciation: "Амортизация"
        case .other: "Друго"
        case .unknown: "—"
        }
    }
}

/// WHICH land a cost spreads over (agri-saas `COST_ALLOCATION_BASES`). Only
/// what this app sends is modelled: `HOLDING`, the whole farm by area — «Цялото
/// стопанство» on the web, «включително собствените» имоти, with land carrying
/// no crop keeping its share and reported apart.
enum CostAllocationBasis: String, Sendable {
    case holding = "HOLDING"
}

/// What the app SENDS to create one.
///
/// ── Numbers out, strings back ──
///
/// `amount` is `z.number()` on the way in and a `Decimal(14,2)` column on
/// the way out, and the route returns the raw row — so the same field is a
/// number in this struct and a `DecimalString` in the response. That
/// asymmetry is the server's, not a modelling choice here.
///
/// ── The bounds are the server's, mirrored ──
///
/// `amount` must be finite, strictly greater than zero, and at most
/// 999_999_999_999. Checked here so an operator is told before the request
/// rather than after it, and checked there because a client is not a
/// validator.
struct CreateCostEntry: Encodable, Sendable {
    let category: CostCategory
    let amount: Decimal
    let currency: String
    /// `incurredOn` is a STRING with a minimum length of 8, not a date. The
    /// calculator payload already carries one date-only field
    /// (`priceObservedAt`, yyyy-mm-dd) that must not be typed as `Date`,
    /// and this is the write-side twin.
    let incurredOn: String
    let supplier: String?
    let description: String?

    /// WHICH land the cost spreads over. Absent is the server's `TARGET` — the
    /// one-line form's behaviour, unchanged. The «Режийни» sheet sends
    /// `HOLDING`: the whole farm, by area (owner, 2026-10-09: salaries «per
    /// dca of the whole farm, not only over a given crop decares»).
    var allocationBasis: CostAllocationBasis? = nil

    /// A salary entered as people × a yearly salary each — BOTH or NEITHER,
    /// and only on PAYROLL (agri-saas #1518). An input aid, not a constraint:
    /// `amount` stays authoritative and is not checked against the product,
    /// since a hire who started in May makes a true total that does not match.
    /// Absent — never zero — for a total typed as a total.
    var payrollHeadcount: Int? = nil
    var payrollAnnualPerPerson: Decimal? = nil

    /// Optional, so every existing call site builds the same one-line draft —
    /// and, being omitted when nil, mints the same idempotency key it always
    /// did (`CostIdempotencyKey` hashes the encoded body).
    enum CodingKeys: String, CodingKey {
        case category, amount, currency, incurredOn, supplier, description
        case allocationBasis, payrollHeadcount, payrollAnnualPerPerson
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(category.rawValue, forKey: .category)
        // As a NUMBER. `Decimal` encodes as a JSON number, which is what
        // `z.number()` requires — encoding the description string would be
        // rejected, and going via `Double` would reintroduce the binary
        // rounding `DecimalString` exists to avoid.
        try c.encode(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(incurredOn, forKey: .incurredOn)
        try c.encodeIfPresent(supplier, forKey: .supplier)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(allocationBasis?.rawValue, forKey: .allocationBasis)
        try c.encodeIfPresent(payrollHeadcount, forKey: .payrollHeadcount)
        try c.encodeIfPresent(payrollAnnualPerPerson, forKey: .payrollAnnualPerPerson)
    }

    /// The server's bounds, mirrored so the operator learns before the
    /// request rather than after it.
    static let maxAmount = Decimal(string: "999999999999")!

    enum Invalid: Equatable {
        case amountNotPositive
        case amountTooLarge
        case currencyMissing
        case dateMissing
    }

    var problems: [Invalid] {
        var found: [Invalid] = []
        if amount <= 0 { found.append(.amountNotPositive) }
        if amount > Self.maxAmount { found.append(.amountTooLarge) }
        if currency.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(.currencyMissing)
        }
        if incurredOn.count < 8 { found.append(.dateMissing) }
        return found
    }
}
