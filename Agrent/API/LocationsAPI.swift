import Foundation

enum LocationsAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/locations" }

    /// A BARE ARRAY, not an envelope. Measured.
    static var listPath: String { base }

    /// The parcels live HERE, not on the location detail: that route returns a
    /// flat row with no `parcels` key at all. The optional-parcels DTO on the
    /// server documents `getLocationWithParcels`, which nothing calls.
    static func parcelsPath(_ locationID: String) -> String { "\(base)/\(locationID)/parcels" }

    static func decodeList(from data: Data) async throws -> [Location] {
        try await APIClient.shared.decode(data, as: [Location].self)
    }

    static func decodeParcels(from data: Data) async throws -> ParcelsResponse {
        try await APIClient.shared.decode(data, as: ParcelsResponse.self)
    }
}
