import Foundation

/// The cross-tenant grain marketplace.
///
/// Modelled from bytes captured off the live wire on 2026-09-21, scrubbed of
/// identifiers and committed as `Tests/Fixtures/exchange-*.json`. Unlike the
/// calculator, this endpoint HAS production data, so the shapes below were
/// observed rather than described.
///
/// THREE THINGS THE WIRE SAID THAT THE WRITTEN CONTRACT DID NOT:
///
/// 1. The path is `/api/t/{slug}/exchange/...`. The roadmap's
///    `/api/exchange/listings` returns 404 — measured, both tried.
///
/// 2. DECIMALS ARRIVE AS STRINGS. `quantityTonnes: "250"`,
///    `pricePerTonne: "51.13"` — Prisma `Decimal` serialises as a JSON string,
///    not a number. Typing either as `Double` fails the WHOLE payload. They
///    are kept as the strings they are, with `Decimal` parsed on demand:
///    `Decimal(string:)` is exact where `Double` would introduce binary
///    rounding into a price.
///
/// 3. THE TWO ENDPOINTS DISAGREE ON ENVELOPE. `listings` answers
///    `{ rows, nextCursor }`; `my-listings` answers a BARE ARRAY, and its rows
///    carry an extra `inquiries` field. Same domain, two shapes — the
///    journal's situation again.
///
/// TENANT SCOPING IS NOT WHAT THE URL SUGGESTS. The slug in the path is for
/// auth and context only. `ExchangeListing` is a GLOBAL table with no
/// tenantId and no RLS, by design: cross-tenant readability is the product,
/// and `description`/`sellerDisplayName` are sanitised public plaintext.
/// `isOwn` is the only thing distinguishing your rows. Inquiries are the
/// opposite — RLS-protected, private between buyer and seller — so the two
/// must not share a UI that treats them alike.
struct ExchangeListing: Decodable, Equatable, Sendable, Identifiable {
    let id: String

    let side: ExchangeSide
    let kind: ExchangeKind
    let status: ExchangeListingStatus

    let commodity: String

    /// Strings on the wire. See the type header.
    let quantityTonnes: String?
    let pricePerTonne: String?
    let priceCurrency: String?

    let regionCode: String?
    let regionName: String?
    let lat: Double?
    let lon: Double?

    /// Public plaintext by design, and null when the seller set none.
    let description: String?
    let sellerDisplayName: String?

    let createdAt: Date
    let expiresAt: Date?

    /// The only marker separating your listings from every other tenant's.
    let isOwn: Bool

    /// Parsed with an EXPLICIT wire locale. `Decimal(string:)` without one
    /// is a hazard: the wire uses `.` regardless of the device, and a
    /// locale that groups with `.` reads "12.5" as 125 — a factor of ten,
    /// on a tonnage someone is pricing against.
    ///
    /// These are the canonical STRING decimals of this API. The exchange
    /// routes have no DTO, so their `Decimal` columns reach
    /// `JSON.stringify` raw; `grain/costs` maps through one and sends
    /// numbers. Same database type, two wire types, per route — see
    /// `WireDecimal`.
    var quantity: Decimal? { WireDecimal.parse(quantityTonnes) }
    var price: Decimal? { WireDecimal.parse(pricePerTonne) }

    var isActive: Bool { status == .active }
}

/// `GET /api/t/{slug}/exchange/listings` — envelope, paged.
struct ExchangeListingPage: Decodable, Equatable, Sendable {
    let rows: [ExchangeListing]
    let nextCursor: String?
}

/// `GET /api/t/{slug}/exchange/my-listings` — a BARE ARRAY of these, not an
/// envelope. The extra `inquiries` field is why this is a separate type
/// rather than a reuse of `ExchangeListing`.
struct OwnExchangeListing: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let side: ExchangeSide
    let kind: ExchangeKind
    let status: ExchangeListingStatus
    let commodity: String
    let quantityTonnes: String?
    let pricePerTonne: String?
    let priceCurrency: String?
    let regionCode: String?
    let regionName: String?
    let lat: Double?
    let lon: Double?
    let description: String?
    let sellerDisplayName: String?
    let createdAt: Date
    let expiresAt: Date?
    let isOwn: Bool

    /// Empty in every row observed, so the ELEMENT type is unobserved. Decoded
    /// leniently for that reason: an element that does not match is dropped
    /// rather than failing the seller's whole listing page. A seller who
    /// cannot load this page cannot withdraw a listing — which is why the
    /// route is deliberately not module-gated server-side.
    let inquiries: [ExchangeInquiry]

    /// Parsed with an EXPLICIT wire locale. `Decimal(string:)` without one
    /// is a hazard: the wire uses `.` regardless of the device, and a
    /// locale that groups with `.` reads "12.5" as 125 — a factor of ten,
    /// on a tonnage someone is pricing against.
    ///
    /// These are the canonical STRING decimals of this API. The exchange
    /// routes have no DTO, so their `Decimal` columns reach
    /// `JSON.stringify` raw; `grain/costs` maps through one and sends
    /// numbers. Same database type, two wire types, per route — see
    /// `WireDecimal`.
    var quantity: Decimal? { WireDecimal.parse(quantityTonnes) }
    var price: Decimal? { WireDecimal.parse(pricePerTonne) }

    private enum CodingKeys: String, CodingKey {
        case id, side, kind, status, commodity, quantityTonnes, pricePerTonne
        case priceCurrency, regionCode, regionName, lat, lon, description
        case sellerDisplayName, createdAt, expiresAt, isOwn, inquiries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        side = try c.decode(ExchangeSide.self, forKey: .side)
        kind = try c.decode(ExchangeKind.self, forKey: .kind)
        status = try c.decode(ExchangeListingStatus.self, forKey: .status)
        commodity = try c.decode(String.self, forKey: .commodity)
        quantityTonnes = try c.decodeIfPresent(String.self, forKey: .quantityTonnes)
        pricePerTonne = try c.decodeIfPresent(String.self, forKey: .pricePerTonne)
        priceCurrency = try c.decodeIfPresent(String.self, forKey: .priceCurrency)
        regionCode = try c.decodeIfPresent(String.self, forKey: .regionCode)
        regionName = try c.decodeIfPresent(String.self, forKey: .regionName)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        sellerDisplayName = try c.decodeIfPresent(String.self, forKey: .sellerDisplayName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        isOwn = try c.decode(Bool.self, forKey: .isOwn)

        if var list = try? c.nestedUnkeyedContainer(forKey: .inquiries) {
            var found: [ExchangeInquiry] = []
            while !list.isAtEnd {
                if let item = try? list.decode(ExchangeInquiry.self) {
                    found.append(item)
                } else {
                    _ = try? list.decode(AnySkipped.self)
                }
            }
            inquiries = found
        } else {
            inquiries = []
        }
    }

    private struct AnySkipped: Decodable {}
}

/// Private buyer↔seller message. RLS-protected on `inquirerTenantId`, with a
/// disjunctive policy because an inquiry has two legitimate parties: the
/// inquirer, or the seller resolved through the listing.
///
/// CONTACT DETAILS ARE WITHHELD BY THE PROJECTION, not hidden by the client.
/// `contactSharedAt` is the enforcement point: while it is null neither
/// party's contact is sent at all, so a PENDING or DECLINED inquiry leaks
/// nothing. The absence of a contact field is the product working — never
/// render a placeholder implying one exists.
///
/// Shape is UNOBSERVED: every `inquiries` array on the wire was empty. The
/// fields below are all optional so that a real one cannot fail to decode,
/// and this type should be re-derived from a live payload before anything is
/// built on it.
struct ExchangeInquiry: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let status: ExchangeInquiryStatus?
    let message: String?
    let createdAt: Date?
    let contactSharedAt: Date?

    var contactShared: Bool { contactSharedAt != nil }
}


// MARK: - Server vocabularies

/// From `prisma/schema/enums.prisma`. All four are lenient: an unrecognised
/// value costs a vague label, never the payload. Written out because
/// inventing a vocabulary is the `LogEntryType` mistake and observing only
/// part of one is how that happened.
///
/// Observed on the wire: SELL, CULTURE, ACTIVE, EXPIRED. The rest come from
/// the schema — including `WITHDRAWN`, which is the state the my-listings
/// custody exemption exists to let a seller reach.
enum ExchangeSide: String, CaseIterable, LenientDecodable, Sendable {
    static var unknownCase: ExchangeSide { .unknown }
    case sell = "SELL"
    case buy = "BUY"
    case unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .sell: "Продава"
        case .buy: "Купува"
        case .unknown: "—"
        }
    }
}

/// `ExchangeKind`, not `ExchangeListingKind` — the field name does not give
/// the type name here.
enum ExchangeKind: String, CaseIterable, LenientDecodable, Sendable {
    static var unknownCase: ExchangeKind { .unknown }
    case culture = "CULTURE"
    case fertilizer = "FERTILIZER"
    case seeds = "SEEDS"
    case product = "PRODUCT"
    case unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .culture: "Култура"
        case .fertilizer: "Тор"
        case .seeds: "Семена"
        case .product: "Продукт"
        case .unknown: "Друго"
        }
    }
}

enum ExchangeListingStatus: String, CaseIterable, LenientDecodable, Sendable {
    static var unknownCase: ExchangeListingStatus { .unknown }
    case active = "ACTIVE"
    case fulfilled = "FULFILLED"
    case withdrawn = "WITHDRAWN"
    case expired = "EXPIRED"
    case unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .active: "Активна"
        case .fulfilled: "Изпълнена"
        case .withdrawn: "Оттеглена"
        case .expired: "Изтекла"
        case .unknown: "—"
        }
    }
}

enum ExchangeInquiryStatus: String, CaseIterable, LenientDecodable, Sendable {
    static var unknownCase: ExchangeInquiryStatus { .unknown }
    case pending = "PENDING"
    case accepted = "ACCEPTED"
    case declined = "DECLINED"
    case unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .pending: "Чака отговор"
        case .accepted: "Приета"
        case .declined: "Отказана"
        case .unknown: "—"
        }
    }
}
