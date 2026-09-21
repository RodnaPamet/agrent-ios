import CoreLocation
import MapKit
import XCTest
@testable import Agrent

/// Bulgaria, generously. Any coordinate outside this is a swap, not a farm.
private let bgLat = 41.0...44.5
private let bgLon = 22.0...28.5

final class LocationGeometryTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        else {
            XCTFail("\(name).json missing from the test bundle")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func parcels() async throws -> ParcelsResponse {
        try await APIClient.shared.decode(fixture("locations-parcels"), as: ParcelsResponse.self)
    }

    // MARK: - Coordinate order

    /// The assertion that matters. A decode test passes whether or not the
    /// axes are crossed; only checking WHERE the result lands catches it.
    func testEveryCoordinateLandsInBulgaria() async throws {
        var checked = 0
        for parcel in try await parcels().parcels {
            guard let geometry = parcel.geometry else { continue }
            for polygon in geometry.coordinates {
                for ring in polygon {
                    for point in ring {
                        let c = try XCTUnwrap(ParcelGeometry.coordinate(from: point))
                        XCTAssertTrue(bgLat.contains(c.latitude),
                                      "latitude \(c.latitude) outside Bulgaria — axes swapped?")
                        XCTAssertTrue(bgLon.contains(c.longitude),
                                      "longitude \(c.longitude) outside Bulgaria — axes swapped?")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "fixture should exercise real vertex counts")
    }

    /// Proves the test above can actually fail: the swapped mapping puts the
    /// same point in the Red Sea. Without this, a bounds assertion that always
    /// passes looks identical to one that works.
    func testSwappedMappingWouldLeaveBulgaria() {
        let point = [25.150, 42.550]  // [lon, lat]
        let correct = CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
        let swapped = CLLocationCoordinate2D(latitude: point[0], longitude: point[1])

        XCTAssertTrue(bgLat.contains(correct.latitude))
        XCTAssertTrue(bgLon.contains(correct.longitude))
        XCTAssertFalse(bgLat.contains(swapped.latitude), "swap must be detectable")
        XCTAssertFalse(bgLon.contains(swapped.longitude))
    }

    /// `bounds` carries the same order, and getting it wrong aims the camera
    /// at the Red Sea while leaving the map looking merely empty.
    func testBoundsAreLongitudeFirst() async throws {
        let response = try await parcels()
        let bounds = try XCTUnwrap(response.bounds)
        XCTAssertEqual(bounds.minLon, 25.1000, accuracy: 0.0001)
        XCTAssertEqual(bounds.minLat, 42.5000, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxLon, 25.2000, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxLat, 42.6000, accuracy: 0.0001)

        let region = bounds.region
        XCTAssertTrue(bgLat.contains(region.center.latitude), "camera latitude off-country")
        XCTAssertTrue(bgLon.contains(region.center.longitude), "camera longitude off-country")
    }

    // MARK: - Holes

    /// Production's parcel 15655-19 is one polygon with five rings. Flattening
    /// would draw four holes as land across 32 hectares.
    func testHolesBecomeInteriorPolygonsNotOutlines() async throws {
        let response = try await parcels()
        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_holes" })
        let geometry = try XCTUnwrap(parcel.geometry)
        XCTAssertEqual(geometry.coordinates.count, 1, "one polygon")
        XCTAssertEqual(geometry.coordinates[0].count, 5, "outer ring plus four holes")

        let polygons = geometry.mapPolygons
        XCTAssertEqual(polygons.count, 1, "five rings are ONE polygon, not five")
        XCTAssertEqual(polygons[0].interiorPolygons?.count, 4, "four holes")
    }

    func testSimpleParcelHasNoInteriorPolygons() async throws {
        let response = try await parcels()
        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_simple" })
        let polygons = try XCTUnwrap(parcel.geometry).mapPolygons
        XCTAssertEqual(polygons.count, 1)
        XCTAssertNil(polygons[0].interiorPolygons)
    }

    // MARK: - Fail-soft geometry

    /// A parcel with null geometry EXISTS but cannot be drawn. It belongs in
    /// the list and out of the map — not treated as an error, and not dropped.
    func testNullGeometryParcelSurvivesDecoding() async throws {
        let response = try await parcels()
        XCTAssertEqual(response.parcels.count, 3, "the undrawable parcel is still a parcel")

        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_nogeom" })
        XCTAssertNil(parcel.geometry)
        XCTAssertFalse(parcel.isDrawable)
        XCTAssertEqual(parcel.areaHa, 5.0, "it still has an area to show in a list")

        XCTAssertEqual(response.parcels.filter(\.isDrawable).count, 2)
    }

    // MARK: - Shapes and types

    /// areaHa is a NUMBER here, unlike the exchange's string decimals.
    func testAreaIsANumberNotAString() async throws {
        let response = try await parcels()
        let parcel = try XCTUnwrap(response.parcels.first)
        XCTAssertEqual(parcel.areaHa, 32.478)
    }

    /// A reversed box must FAIL, not be quietly absorbed.
    ///
    /// Before the guard, `abs()` in latSpan/lonSpan turned swapped corners
    /// into a correct-looking span, and the centre is order-independent — so
    /// MapKit would have centred and sized a region perfectly from nonsense.
    func testReversedBoundsAreRejectedAtDecode() throws {
        let reversed = Data("[25.2, 42.6, 25.1, 42.5]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BoundingBox.self, from: reversed))

        let ordered = Data("[25.1, 42.5, 25.2, 42.6]".utf8)
        let box = try JSONDecoder().decode(BoundingBox.self, from: ordered)
        XCTAssertEqual(box.lonSpan, 0.1, accuracy: 1e-9)
        XCTAssertEqual(box.latSpan, 0.1, accuracy: 1e-9)
    }

    /// The list endpoint is a bare array, and the raw Prisma row's extra
    /// fields must be ignored rather than break the decode.
    func testLocationListIsABareArrayAndIgnoresUnmodelledFields() async throws {
        let rows = try await APIClient.shared.decode(fixture("locations-list"), as: [Location].self)
        XCTAssertEqual(rows.count, 1)
        let location = try XCTUnwrap(rows.first)
        XCTAssertEqual(location.name, "Synthetic Land")
        XCTAssertEqual(location.parcelCount, 3, "_count maps to parcelCount")
        XCTAssertEqual(location.kind, "FIELD")
        let bounds = try XCTUnwrap(location.boundsJson, "boundsJson decodes as a BoundingBox")
        XCTAssertEqual(bounds.minLon, 25.1, accuracy: 0.0001)
    }
}
