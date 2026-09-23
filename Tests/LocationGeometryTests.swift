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

    // MARK: - The simplified map's rectangle

    /// The box has to COVER the field, or the simplified map would show a
    /// rectangle that the precise map's outline pokes out of.
    func testBoundingBoxCoversTheWholeParcel() async throws {
        let response = try await parcels()
        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_holes" })
        let geometry = try XCTUnwrap(parcel.geometry)

        let box = try XCTUnwrap(geometry.boundingMapPolygon).boundingMapRect
        var union = geometry.mapPolygons[0].boundingMapRect
        for polygon in geometry.mapPolygons.dropFirst() {
            union = union.union(polygon.boundingMapRect)
        }

        // Within a map point rather than exactly. The corners are built in
        // projected space, handed to MapKit as coordinates, and projected
        // back when MKPolygon recomputes its own rect — a round trip that
        // costs a fraction of a map point, which is under 15cm on the
        // ground. Asserting equality would fail on that and teach the next
        // reader that the box is wrong when it is the assertion that is.
        XCTAssertEqual(box.minX, union.minX, accuracy: 1)
        XCTAssertEqual(box.minY, union.minY, accuracy: 1)
        XCTAssertEqual(box.maxX, union.maxX, accuracy: 1)
        XCTAssertEqual(box.maxY, union.maxY, accuracy: 1)
    }

    /// Four corners and no holes. `par_holes` has four interior rings across
    /// 32 hectares; the simplification is precisely that they stop existing.
    func testBoundingBoxIsFourCornersAndDropsHoles() async throws {
        let response = try await parcels()
        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_holes" })
        let box = try XCTUnwrap(try XCTUnwrap(parcel.geometry).boundingMapPolygon)

        XCTAssertEqual(box.pointCount, 4)
        XCTAssertNil(box.interiorPolygons, "a box has no holes — that is the point")
    }

    /// Nil rather than a zero-sized rectangle, so a caller can tell "nothing
    /// to draw" from "something of no size".
    func testBoundingBoxIsNilWhenNothingIsDrawable() throws {
        let degenerate = try JSONDecoder().decode(
            ParcelGeometry.self,
            from: Data(#"{"type":"Polygon","coordinates":[[[[25.1,42.5],[25.2,42.6]]]]}"#.utf8))
        XCTAssertTrue(degenerate.mapPolygons.isEmpty, "two points is not a ring")
        XCTAssertNil(degenerate.boundingMapPolygon)
    }

    /// The box lands on the farm. Same trap as everywhere else in this file:
    /// crossed axes give a well-formed rectangle in the Red Sea.
    func testBoundingBoxLandsInBulgaria() async throws {
        let response = try await parcels()
        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_simple" })
        let box = try XCTUnwrap(try XCTUnwrap(parcel.geometry).boundingMapPolygon)
        XCTAssertTrue(bgLat.contains(box.coordinate.latitude))
        XCTAssertTrue(bgLon.contains(box.coordinate.longitude))
    }

    // MARK: - Sown inference

    /// Moved here with `isSown` itself. It is a fact about a parcel, and it
    /// outlives any one map that draws it.
    func testSownIsInferredFromCropAndIsNotAServerField() throws {
        func parcel(crop: String?) throws -> Parcel {
            let cropJSON = crop.map { "\"\($0)\"" } ?? "null"
            return try JSONDecoder().decode(Parcel.self, from: Data("""
            {"id":"p","name":"n","cropType":\(cropJSON),"areaHa":1,"geometry":null,
             "soilType":null,"cadastralId":null,"ekatte":null,"hasActiveLease":false}
            """.utf8))
        }
        XCTAssertTrue(try parcel(crop: "Wheat").isSown)
        XCTAssertFalse(try parcel(crop: nil).isSown)
        XCTAssertFalse(try parcel(crop: "").isSown, "an empty crop is not a crop")
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

/// The remount guard, which is the one part of the two-shape switch that can
/// fail silently. Pure and static, so it needs no `MKMapView`.
final class ParcelShapeMountKeyTests: XCTestCase {

    private func parcel(_ id: String) throws -> Parcel {
        try JSONDecoder().decode(Parcel.self, from: Data("""
        {"id":"\(id)","name":"n","cropType":null,"areaHa":1,"geometry":null,
         "soilType":null,"cadastralId":null,"ekatte":null,"hasActiveLease":false}
        """.utf8))
    }

    /// THE regression this guards. The same fields drawn differently must not
    /// compare equal, or the toggle returns early and nothing on screen moves.
    @MainActor
    func testSameParcelsInDifferentShapesDoNotCompareEqual() throws {
        let parcels = [try parcel("a"), try parcel("b")]
        XCTAssertNotEqual(
            SatelliteParcelMap.Coordinator.mountKey(parcels, .outlines),
            SatelliteParcelMap.Coordinator.mountKey(parcels, .boundingBoxes))
    }

    @MainActor
    func testSameParcelsInTheSameShapeCompareEqual() throws {
        let parcels = [try parcel("a"), try parcel("b")]
        XCTAssertEqual(
            SatelliteParcelMap.Coordinator.mountKey(parcels, .outlines),
            SatelliteParcelMap.Coordinator.mountKey(parcels, .outlines),
            "an identical update must not remount a loaded overlay")
    }

    @MainActor
    func testADifferentParcelSetRemounts() throws {
        XCTAssertNotEqual(
            SatelliteParcelMap.Coordinator.mountKey([try parcel("a")], .outlines),
            SatelliteParcelMap.Coordinator.mountKey([try parcel("b")], .outlines))
    }

    /// A box is ONE rectangle for the parcel, however many polygons it has.
    @MainActor
    func testBoxesAreOnePolygonPerParcelAndOutlinesAreNot() async throws {
        let data = try Data(contentsOf: XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "locations-parcels", withExtension: "json")))
        let response = try await APIClient.shared.decode(data, as: ParcelsResponse.self)
        let parcel = try XCTUnwrap(response.parcels.first { $0.id == "par_holes" })

        let outlines = SatelliteParcelMap.Coordinator.polygons(for: parcel, shape: .outlines)
        let boxes = SatelliteParcelMap.Coordinator.polygons(for: parcel, shape: .boundingBoxes)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(outlines[0].interiorPolygons?.count, 4, "the outline keeps its holes")
        XCTAssertNil(boxes[0].interiorPolygons, "the box does not")
    }

    /// A parcel with no geometry contributes nothing in either shape, rather
    /// than a zero-sized rectangle sitting invisibly on the map.
    @MainActor
    func testUndrawableParcelContributesNoOverlay() throws {
        let bare = try parcel("nope")
        XCTAssertTrue(SatelliteParcelMap.Coordinator.polygons(for: bare, shape: .outlines).isEmpty)
        XCTAssertTrue(SatelliteParcelMap.Coordinator.polygons(for: bare, shape: .boundingBoxes).isEmpty)
    }
}
