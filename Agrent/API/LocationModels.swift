import Foundation

/// Locations and parcels.
///
/// Modelled from bytes measured off the live wire on 2026-09-21. Three
/// endpoints, THREE DIFFERENT SHAPES — do not assume a convention:
///
///     /locations                  BARE ARRAY of Location
///     /locations/{id}             FLAT OBJECT, and it carries NO `parcels`.
///                                 The optional-parcels DTO in the server
///                                 describes `getLocationWithParcels`, which
///                                 nothing calls. Use the third endpoint.
///     /locations/{id}/parcels     OBJECT { locationId, bounds, parcels }
///
/// FIELDS DELIBERATELY NOT MODELLED. The location route returns a raw Prisma
/// row — `include`, not `select` — so the wire carries about 21 fields where
/// the published spec documents 14. `tenantId`, `createdByUserId`,
/// `deletedByUserId`, `deletedAt`, `retentionUntil`, `spatialFileId` and
/// `isSampleData` are soft-delete bookkeeping, retention policy and internal
/// user ids that a mobile client has no use for. Decodable ignores what it is
/// not asked for.
///
/// Note that NOT modelling them does not keep them off the device:
/// `ResponseCache` stores the raw response bytes, so they land in
/// Library/Caches regardless — behind file protection, but present. The fix
/// for that is server-side projection, raised separately.
struct Location: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let status: String
    let kind: String
    let capacityTonnes: Double?
    let createdAt: Date
    let updatedAt: Date?

    /// `[minLon, minLat, maxLon, maxLat]` — see `BoundingBox`.
    let boundsJson: BoundingBox?

    let counts: Counts?

    struct Counts: Decodable, Equatable, Sendable {
        let parcels: Int
    }

    /// How many parcels exist, from `_count`. The detail endpoint gives this
    /// INSTEAD of the parcels themselves, so it is the only way to show a
    /// count without a second request.
    var parcelCount: Int? { counts?.parcels }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, status, kind, capacityTonnes
        case createdAt, updatedAt, boundsJson
        case counts = "_count"
    }
}

/// A geographic extent, decoded from a four-element GeoJSON-order array.
///
/// THE ORDER IS LONGITUDE FIRST: `[minLon, minLat, maxLon, maxLat]`. Measured:
/// `[24.2001, 43.1079, 24.3047, 43.1964]` for a farm in Pleven, which is ~43°N
/// ~24°E.
///
/// This is a named type rather than `[Double]` precisely so the order cannot
/// be applied positionally by a later reader. Fed straight into an
/// `MKCoordinateRegion` the wrong way round it puts the CAMERA near 24°N 43°E
/// — and that failure is nastier than misplaced polygons, because the parcels
/// are then merely off-screen and an empty map reads as "no data" rather than
/// as a bug.
struct BoundingBox: Decodable, Equatable, Sendable {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double

    /// Ordering is guarded HERE, at the boundary, rather than downstream.
    ///
    /// A reversed box used to SURVIVE rather than merely pass: `latSpan` and
    /// `lonSpan` took `abs()`, so swapped corners produced a correct-looking
    /// span, and `centerLat`/`centerLon` are order-independent so they came
    /// out right too. Everything downstream got plausible numbers and nothing
    /// noticed — MapKit would centre and size a region perfectly from a box
    /// whose corners were the wrong way round. That `abs()` was not
    /// tolerating bad input, it was destroying the evidence of it.
    ///
    /// The only place it surfaced was the schematic projection, where
    /// `maxLat - lat` goes negative and the farm draws off-screen — an
    /// accident of that arithmetic, not a check anyone designed.
    ///
    /// So it fails loudly at the one point the data arrives, and the spans
    /// below no longer take `abs()`: with ordering guaranteed it could never
    /// fire, and leaving it would tell the next reader that reversed boxes
    /// are expected here.
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        minLon = try c.decode(Double.self)
        minLat = try c.decode(Double.self)
        maxLon = try c.decode(Double.self)
        maxLat = try c.decode(Double.self)

        guard maxLon >= minLon, maxLat >= minLat else {
            let seen = "[\(minLon), \(minLat), \(maxLon), \(maxLat)]"
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Bounds corners reversed: \(seen). Expected [minLon, minLat, maxLon, maxLat]."
            ))
        }
    }

    init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon
        self.minLat = minLat
        self.maxLon = maxLon
        self.maxLat = maxLat
    }

    var centerLat: Double { (minLat + maxLat) / 2 }
    var centerLon: Double { (minLon + maxLon) / 2 }
    var latSpan: Double { maxLat - minLat }
    var lonSpan: Double { maxLon - minLon }
}

/// `GET /locations/{id}/parcels` — an object, not an array.
struct ParcelsResponse: Decodable, Equatable, Sendable {
    let locationId: String
    let bounds: BoundingBox?
    let parcels: [Parcel]
}

/// `Identifiable` AND `Hashable` so a tap can drive `sheet(item:)`,
/// which carries the parcel with it. A separate Bool plus a stored parcel
/// can disagree, and the disagreement writes an operation against the
/// wrong field.
struct Parcel: Decodable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let cropType: String?

    /// A NUMBER here, unlike the exchange's `quantityTonnes`, which is a
    /// string. Same codebase, two conventions, both verified — do not carry
    /// the exchange's decimal-as-string habit across.
    let areaHa: Double?

    /// Null means the parcel EXISTS but cannot be drawn: the server's
    /// `parseGeometry` fails soft and returns null rather than erroring. Such
    /// a parcel belongs in the list and out of the map. Not exercised by
    /// production data on this tenant — modelled, not verified.
    let geometry: ParcelGeometry?

    let soilType: String?
    let cadastralId: String?
    let ekatte: String?
    let hasActiveLease: Bool?

    /// `properties`, `soilJson` and `companyOwners` are NOT modelled.
    /// `properties` in particular has arbitrary keys with mixed value types —
    /// `{"NTP": "100000", "NAME": "19", "YEAR": 2026}` mixes String and Int in
    /// one object, so even `[String: String]` would fail the whole payload.
    /// That is the `netWorthUnavailableParams` situation again.
    var isDrawable: Bool { geometry?.hasDrawableRing == true }

    /// Sown versus fallow is INFERRED from whether a crop is recorded — the
    /// server has no such field. It is the only signal available and it
    /// matches what the legend claims, but it is an inference: a parcel sown
    /// with an unrecorded crop reads as fallow here.
    ///
    /// It lived in the schematic renderer's file until the simplified
    /// satellite map needed it too. A fact about a parcel defined inside one
    /// view is a fact that disappears when that view does, which is exactly
    /// what was about to happen to it.
    var isSown: Bool { !(cropType ?? "").isEmpty }

    /// Hashed on `id` alone rather than synthesised over every field.
    /// The id IS the identity — two values with the same id are the same
    /// parcel whatever else differs — and synthesising would drag
    /// `ParcelGeometry` into `Hashable` for nothing, a four-deep
    /// coordinate array hashed on every sheet presentation.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// GeoJSON MultiPolygon, already parsed server-side — this is an OBJECT on the
/// wire, not a string.
///
/// NESTING IS FOUR DEEP: `coordinates[polygon][ring][point][lon, lat]`.
///
/// Ring 0 of each polygon is the OUTER boundary; every further ring is a HOLE.
/// This is not hypothetical — the owner's parcel `15655-19` is one polygon
/// with FIVE rings, so four holes, on day one. Flattening all rings into a
/// single polygon draws those holes as solid land across a 32-hectare field.
struct ParcelGeometry: Decodable, Equatable, Sendable {
    let type: String
    let coordinates: [[[[Double]]]]

    var isMultiPolygon: Bool { type == "MultiPolygon" }
}
