import Foundation

/// `GET /parcels/by-crop`: the farm's parcels by crop, across every block
/// (agri-saas #1746, built for «Ново мероприятие», agrent-ios#293).
///
/// Two answers behind one path, chosen by `crop`:
/// - without it, the farm's crops — each value as stored, with how many
///   parcels carry it and their total hectares, and no geometry;
/// - with it, that crop's parcels, each with the block it sits in and a
///   simplified outline for a picker map.
///
/// Before it, step two read every block and then each block's parcels.
enum ParcelsByCropAPI {
    static var path: String { "\(FarmPath.root)/parcels/by-crop" }

    /// One crop's parcels. The value is one the crop list returned —
    /// matched case-insensitive and trimmed by the server; an unknown one is
    /// an empty list, not a 404.
    static func path(crop: String) -> String {
        "\(path)?crop=\(URLEscape.queryValue(crop))"
    }

    struct CropTotals: Decodable, Equatable, Sendable {
        let crops: [CropTotal]
    }

    struct CropTotal: Decodable, Equatable, Sendable {
        /// As stored, verbatim — usually a `crops` catalogue value, but an
        /// import can stamp anything («Winter Wheat»).
        let cropType: String
        let parcelCount: Int
        /// Hectares; nil when none of the parcels has a measured area.
        let areaHaTotal: Double?
    }

    struct CropParcels: Decodable, Equatable, Sendable {
        let cropType: String
        let parcels: [CropParcel]
    }

    struct CropParcel: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let cropType: String
        let areaHa: Double?
        let locationId: String
        let locationName: String
        /// The outline, read LENIENTLY: the server simplifies it for display,
        /// and an outline this build cannot read costs that parcel its shape
        /// on the map — never the list. A plain `Polygon` is taken as a
        /// one-polygon `MultiPolygon`, the shape the map code draws.
        let geometry: ParcelGeometry?

        private enum CodingKeys: String, CodingKey {
            case id, name, cropType, areaHa, locationId, locationName, geometry
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            cropType = try c.decode(String.self, forKey: .cropType)
            areaHa = (try? c.decodeIfPresent(Double.self, forKey: .areaHa)) ?? nil
            locationId = try c.decode(String.self, forKey: .locationId)
            locationName = try c.decode(String.self, forKey: .locationName)
            geometry = (try? c.decodeIfPresent(LenientGeometry.self, forKey: .geometry))?.geometry
        }

        /// As a `Parcel`, so the map code and the ДНЕВНИК fields take it as
        /// they take a block's own parcel. What this route does not carry —
        /// soil, cadastre, lease — is nil.
        var parcel: Parcel {
            Parcel(id: id, name: name, cropType: cropType, areaHa: areaHa, geometry: geometry,
                   soilType: nil, cadastralId: nil, ekatte: nil, hasActiveLease: nil,
                   absentFromImportAt: nil)
        }
    }

    /// `MultiPolygon` as it is; `Polygon` wrapped into one; anything else nil.
    private struct LenientGeometry: Decodable {
        let geometry: ParcelGeometry?

        private enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "MultiPolygon":
                geometry = ParcelGeometry(type: type,
                                          coordinates: try c.decode([[[[Double]]]].self, forKey: .coordinates))
            case "Polygon":
                geometry = ParcelGeometry(type: "MultiPolygon",
                                          coordinates: [try c.decode([[[Double]]].self, forKey: .coordinates)])
            default:
                geometry = nil
            }
        }
    }

    static func decodeTotals(from data: Data) async throws -> CropTotals {
        try await APIClient.shared.decode(data, as: CropTotals.self)
    }

    static func decodeParcels(from data: Data) async throws -> CropParcels {
        try await APIClient.shared.decode(data, as: CropParcels.self)
    }
}
