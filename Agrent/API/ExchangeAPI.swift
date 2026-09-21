import Foundation

enum ExchangeAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/exchange" }

    /// Envelope: `{ rows, nextCursor }`.
    static var listingsPath: String { "\(base)/listings" }

    /// A BARE ARRAY — different envelope from `listings`, same domain.
    static var myListingsPath: String { "\(base)/my-listings" }

    /// A BARE ARRAY. Empty in production, so the element shape is unobserved.
    static var inquiriesPath: String { "\(base)/inquiries" }

    /// Measured: the detail route returns a FLAT listing object, identical in
    /// shape to one row of the list — no envelope, no extra fields. So it
    /// decodes as `ExchangeListing` and needs no type of its own.
    static func listingPath(_ id: String) -> String { "\(base)/listings/\(id)" }

    static func decodeListings(from data: Data) async throws -> ExchangeListingPage {
        try await APIClient.shared.decode(data, as: ExchangeListingPage.self)
    }

    static func decodeMyListings(from data: Data) async throws -> [OwnExchangeListing] {
        try await APIClient.shared.decode(data, as: [OwnExchangeListing].self)
    }

    static func decodeInquiries(from data: Data) async throws -> [ExchangeInquiry] {
        try await APIClient.shared.decode(data, as: [ExchangeInquiry].self)
    }

    /// NOT EXERCISED. This creates a production row AND emails the seller
    /// tenant's admins, so it ships built and unfired by deliberate decision:
    /// the first real operator send is the first real test. Nothing in
    /// development or CI may call it.
    ///
    /// No `Idempotency-Key`, and that is correct rather than an omission. The
    /// DOMAIN is idempotent by construction — `@@unique([listingId,
    /// inquirerTenantId])` means a tenant can express interest in a listing at
    /// most once — which is stronger than a header, because it holds even
    /// against a client that never sends one.
    static func createInquiry(listingID: String, message: String) async throws -> ExchangeInquiry {
        try await APIClient.shared.post(
            "\(base)/inquiries",
            body: CreateInquiry(listingId: listingID, message: message),
            as: ExchangeInquiry.self
        )
    }
}

struct CreateInquiry: Encodable, Sendable {
    let listingId: String
    let message: String
}
