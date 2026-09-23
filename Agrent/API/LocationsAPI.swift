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

    // MARK: - Reference data

    /// Items are the farm's catalogue. Not `?category=` filtered: the
    /// product/fertiliser split is a CLIENT-side negation — see
    /// `InputItem.isFertilizer` — and asking the server for one category
    /// would make the other list impossible to build from the same call.
    static var itemsPath: String { "/api/t/\(Config.tenantSlug)/items" }

    /// `measure=RATE` is not optional: 4 units against 20, and the 20
    /// include `kg`, `ha`, `t` and `%`, none of which is a dose rate.
    ///
    /// `Unit` has no write path and the server caches the list for 24h,
    /// so this is effectively static — cached hard on the device through
    /// the ordinary `CachedResource` path.
    static var rateUnitsPath: String { "/api/t/\(Config.tenantSlug)/units?measure=RATE" }

    /// ALL units, for a product's `defaultUnitId`.
    ///
    /// Not the RATE four. A dose is measured in л/дка; a product is STOCKED
    /// in litres or kilograms, and `createItem` rejects a `defaultUnitId`
    /// that does not resolve — so filtering to rate units here would offer
    /// four choices, none of which is what a product is counted in.
    static var allUnitsPath: String { "/api/t/\(Config.tenantSlug)/units" }

    static func decodeItems(from data: Data) async throws -> [InputItem] {
        try await APIClient.shared.decode(data, as: [InputItem].self)
    }

    static func decodeUnits(from data: Data) async throws -> [Unit] {
        try await APIClient.shared.decode(data, as: [Unit].self)
    }

    // MARK: - Writes

    /// A field operation on one or more parcels.
    ///
    /// SAFE TO RETRY — `field-operation` is one of the four usecases that
    /// honour `Idempotency-Key`, so a replay produces one operation. The
    /// key is minted ONCE by the caller and reused across attempts; a new
    /// key per attempt defeats the dedupe entirely, which is the same rule
    /// `JournalAPI.create` records.
    /// Where a field operation is posted. Named so the outbox can replay
    /// to the same place without reconstructing it from a literal.
    static func operationsPath(_ locationID: String) -> String {
        "\(base)/\(locationID)/operations"
    }

    static func createOperation(
        locationID: String, _ draft: CreateFieldOperation, idempotencyKey: String
    ) async throws -> Data {
        try await APIClient.shared.postReturningData(
            operationsPath(locationID),
            body: draft,
            idempotencyKey: idempotencyKey
        )
    }

    /// Inline crop edit from the parcel sheet.
    static func setCropType(
        locationID: String, parcelID: String, cropType: String?
    ) async throws -> Data {
        try await APIClient.shared.patchReturningData(
            "\(base)/\(locationID)/parcels/\(parcelID)",
            body: ["cropType": cropType]
        )
    }
}
