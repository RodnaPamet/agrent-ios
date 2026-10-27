import Foundation
import MapKit

/// «Ортофотокарта» (#458, owner 2026-10-27): the Ministry of Agriculture's
/// orthophoto under a farm's parcels, with the Ministry's physical blocks
/// (ФБ) and the day the area was flown.
///
/// ── Through our server, never the Ministry's directly ──
///
/// The source (МЗХ's INSPIRE GeoServer) answers plain HTTP only. The owner
/// chose to have agri-saas fetch it and serve it over HTTPS, cached, rather
/// than give the phone an App Transport Security exception for one
/// government address. So every path here is the farm's own API, signed in.
///
/// ── What the source is, measured 2026-10-27 ──
///
/// `RasterData:Orthoimagery_YYYY`, 25 cm, served in Web Mercator. Each year
/// covers about a third of the country on a three-year cycle, so the newest
/// photo of a farm is from one of the last three years. Picking it is the
/// server's job, per tile. `VectorData:Dates_YYYY` gives the flight date and
/// `VectorData:Agricultural_Land_YYYY` the ФБ (`PHBIDENT`, `USAGEBUL`).
///
/// ── Licence ──
///
/// The Ministry publishes none for the imagery. The owner asks МЗХ in
/// writing; the map reaches TestFlight now and the App Store only once they
/// agree.
enum OrthophotoAPI {
    /// The server's switch for the mode (owner, 2026-10-27): on for the
    /// owner's farm and testers, off for everyone else, until МЗХ agrees to
    /// the imagery being shown. Then it is switched on for all, with no app
    /// update. Off, the map button cycles the first two modes only.
    static let flag = "agro.orthophoto"
    /// One 256² Web Mercator tile: the newest year with imagery there.
    /// Strings, so the route guard can build the template.
    static func tilePath(_ z: String, _ x: String, _ y: String) -> String {
        "\(FarmPath.root)/ortho/tiles/\(z)/\(x)/\(y)"
    }

    static func tilePath(_ path: MKTileOverlayPath) -> String {
        tilePath(String(path.z), String(path.x), String(path.y))
    }

    /// The newest year covering an area, and the day it was flown.
    static func coveragePath(_ area: Box) -> String {
        "\(FarmPath.root)/ortho/coverage?bbox=\(area.query)"
    }

    /// The physical blocks (ФБ) crossing an area.
    static func blocksPath(_ area: Box) -> String {
        "\(FarmPath.root)/ortho/blocks?bbox=\(area.query)"
    }

    static func coverage(_ area: Box) async throws -> OrthoCoverage {
        try await APIClient.shared.get(coveragePath(area), as: OrthoCoverage.self)
    }

    static func blocks(_ area: Box) async throws -> OrthoBlocks {
        try await APIClient.shared.get(blocksPath(area), as: OrthoBlocks.self)
    }

    /// A box in degrees, `minLon,minLat,maxLon,maxLat` on the wire: the
    /// order `BoundingBox` and GeoJSON use, never lat-first.
    struct Box: Equatable, Hashable, Sendable {
        let minLon: Double
        let minLat: Double
        let maxLon: Double
        let maxLat: Double

        init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
            self.minLon = minLon
            self.minLat = minLat
            self.maxLon = maxLon
            self.maxLat = maxLat
        }

        init(_ box: BoundingBox) {
            self.init(minLon: box.minLon, minLat: box.minLat, maxLon: box.maxLon, maxLat: box.maxLat)
        }

        init(_ region: MKCoordinateRegion) {
            let lat = region.span.latitudeDelta / 2, lon = region.span.longitudeDelta / 2
            self.init(minLon: region.center.longitude - lon, minLat: region.center.latitude - lat,
                      maxLon: region.center.longitude + lon, maxLat: region.center.latitude + lat)
        }

        /// Five places: about a metre, which is finer than any block, and
        /// short enough that a cached answer is found again on a small pan.
        var query: String {
            [minLon, minLat, maxLon, maxLat]
                .map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), $0) }
                .joined(separator: ",")
        }

        /// The larger side, in degrees: how far out the map is.
        var span: Double { max(maxLon - minLon, maxLat - minLat) }
    }
}

/// `GET …/ortho/coverage`: the newest photo of an area. Every field is
/// optional: an area no year covers has none, and the footer then says only
/// whose imagery it is.
struct OrthoCoverage: Decodable, Equatable, Sendable {
    let year: Int?
    /// `YYYY-MM-DD`.
    let flightDate: String?
    let attribution: String?

    private enum CodingKeys: String, CodingKey { case year, flightDate, attribution }

    init(year: Int?, flightDate: String?, attribution: String?) {
        self.year = year
        self.flightDate = flightDate
        self.attribution = attribution
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = (try? c.decodeIfPresent(Int.self, forKey: .year)) ?? nil
        flightDate = (try? c.decodeIfPresent(String.self, forKey: .flightDate)) ?? nil
        attribution = (try? c.decodeIfPresent(String.self, forKey: .attribution)) ?? nil
    }

    /// The footer: whose photo it is, and the day it was taken where known.
    var footer: String {
        let source = attribution?.recorded ?? "МЗХ"
        guard let day = flightDate.flatMap(BgDate.parseISODay) else { return "Ортофото: \(source)" }
        return "Ортофото: \(source), заснемане \(BgDate.full(day))"
    }
}

/// `GET …/ortho/blocks`: GeoJSON, a FeatureCollection of the Ministry's
/// physical blocks. One odd feature costs that feature, never the map.
struct OrthoBlocks: Decodable, Equatable, Sendable {
    let blocks: [OrthoBlock]
    /// The server stopped at its cap: there are more blocks than drawn.
    let truncated: Bool

    private enum CodingKeys: String, CodingKey { case features, truncated }

    init(blocks: [OrthoBlock], truncated: Bool = false) {
        self.blocks = blocks
        self.truncated = truncated
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let features = (try? c.decode([Lenient].self, forKey: .features)) ?? []
        blocks = features.compactMap(\.block)
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    }

    private struct Lenient: Decodable {
        let block: OrthoBlock?
        init(from decoder: any Decoder) throws { block = try? OrthoBlock(from: decoder) }
    }
}

/// One physical block (ФБ): its number and use, and its rings.
struct OrthoBlock: Decodable, Equatable, Sendable, Identifiable {
    /// `PHBIDENT`, «56722-1033»: what a ДФЗ map prints on it.
    let id: String
    /// «Обработваеми земи».
    let usage: String?
    /// Polygons, each its rings, each ring [lon, lat] pairs: a MultiPolygon,
    /// with a Polygon read as one.
    let polygons: [[[[Double]]]]

    private enum Keys: String, CodingKey { case properties, geometry }
    private enum PropertyKeys: String, CodingKey { case id, usage }
    private enum GeometryKeys: String, CodingKey { case type, coordinates }

    init(id: String, usage: String?, polygons: [[[[Double]]]]) {
        self.id = id
        self.usage = usage
        self.polygons = polygons
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let properties = try c.nestedContainer(keyedBy: PropertyKeys.self, forKey: .properties)
        id = try properties.decode(String.self, forKey: .id)
        usage = (try? properties.decodeIfPresent(String.self, forKey: .usage)) ?? nil
        let geometry = try c.nestedContainer(keyedBy: GeometryKeys.self, forKey: .geometry)
        switch try geometry.decode(String.self, forKey: .type) {
        case "MultiPolygon": polygons = try geometry.decode([[[[Double]]]].self, forKey: .coordinates)
        case "Polygon": polygons = [try geometry.decode([[[Double]]].self, forKey: .coordinates)]
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: geometry,
                                                        debugDescription: "not a polygon")
        }
    }

    /// MapKit's polygons for the block, holes and all.
    var mapPolygons: [OrthoBlockPolygon] {
        polygons.compactMap { rings in
            guard let outer = rings.first.map(Self.coordinates), outer.count >= 3 else { return nil }
            let holes = rings.dropFirst().map(Self.coordinates).filter { $0.count >= 3 }
                .map { MKPolygon(coordinates: $0, count: $0.count) }
            let polygon = OrthoBlockPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes)
            polygon.blockID = id
            return polygon
        }
    }

    /// Where its number goes: the middle of its largest polygon's box.
    var labelPoint: CLLocationCoordinate2D? {
        let outers = polygons.compactMap(\.first).map(Self.coordinates).filter { !$0.isEmpty }
        guard let largest = outers.max(by: { Self.boxArea($0) < Self.boxArea($1) }) else { return nil }
        let lats = largest.map(\.latitude), lons = largest.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max()
        else { return nil }
        return CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    }

    private static func coordinates(_ ring: [[Double]]) -> [CLLocationCoordinate2D] {
        ring.compactMap { pair in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    private static func boxArea(_ ring: [CLLocationCoordinate2D]) -> Double {
        let lats = ring.map(\.latitude), lons = ring.map(\.longitude)
        return ((lats.max() ?? 0) - (lats.min() ?? 0)) * ((lons.max() ?? 0) - (lons.min() ?? 0))
    }
}

/// A block's outline on the map: its own class, so the parcels' code never
/// mistakes one for a parcel (removing it, styling it, or opening it).
final class OrthoBlockPolygon: MKPolygon {
    var blockID = ""
}
