import CoreGraphics
import XCTest
@testable import Agrent

/// The renderer's own orientation, which `ParcelProjectionTests` does NOT
/// cover.
///
/// The projection takes `lon:` and `lat:` as named arguments and is tested to
/// death. But the renderer has to decide which element of a GeoJSON position
/// goes into which — and getting that backwards leaves every projection test
/// green while drawing a transposed farm.
///
/// On the satellite view that error was visible: the parcels landed in the Red
/// Sea instead of on the Hemus motorway. Schematic is now the DEFAULT, and it
/// normalises whatever it is handed to fill the view — so a transposed or
/// mirrored farm still produces a plausible arrangement of polygons with
/// nothing to check it against. These assertions are what is left.
final class SchematicRendererTests: XCTestCase {

    private let bounds = BoundingBoxFixture.pleven
    private let size = CGSize(width: 390, height: 520)

    private func projection() -> ParcelProjection {
        ParcelProjection(bounds: ParcelProjection.Bounds(bounds), size: size, padding: 16)
    }

    /// North must render ABOVE south. Latitude increases northward; screen Y
    /// increases DOWNWARD. A renderer that forgets that flip produces a
    /// vertically mirrored farm — a different bug from a transpose, and
    /// equally invisible without imagery.
    func testNorthRendersAboveSouth() {
        let p = projection()
        let north = SchematicParcelMap.screenPoints([[24.294928, 43.191567]], p)[0]
        let south = SchematicParcelMap.screenPoints([[24.207240, 43.111678]], p)[0]
        XCTAssertLessThan(north.y, south.y, "northern parcel must draw higher on screen")
    }

    /// East must render to the RIGHT. Catches the transpose specifically.
    func testEastRendersRightOfWest() {
        let p = projection()
        let east = SchematicParcelMap.screenPoints([[24.301699, 43.141300]], p)[0]
        let west = SchematicParcelMap.screenPoints([[24.201675, 43.115760]], p)[0]
        XCTAssertGreaterThan(east.x, west.x, "eastern parcel must draw further right")
    }

    /// The renderer reproduces the projection's published vectors exactly —
    /// so the call site is passing lon and lat the right way round.
    func testRendererMatchesProjectionVectors() {
        let p = projection()
        let cases: [(name: String, lon: Double, lat: Double, x: CGFloat, y: CGFloat)] = [
            ("15655-19", 24.207240, 43.111678, 40.3, 450.1),
            ("15655-3", 24.201675, 43.115760, 21.3, 430.9),
            ("20688.13", 24.294928, 43.191567, 340.4, 75.4),
            ("20688.80", 24.301699, 43.141300, 363.5, 311.1),
        ]
        for c in cases {
            let pt = SchematicParcelMap.screenPoints([[c.lon, c.lat]], p)[0]
            XCTAssertEqual(pt.x, c.x, accuracy: 0.15, "\(c.name) x")
            XCTAssertEqual(pt.y, c.y, accuracy: 0.15, "\(c.name) y")
        }
    }

    /// A swap would still land inside the view, which is exactly why a
    /// "does it draw?" check proves nothing. This pins that the wrong mapping
    /// is detectably different rather than merely wrong.
    func testTransposedMappingProducesADifferentPoint() {
        let p = projection()
        let correct = p.point(lon: 24.294928, lat: 43.191567)
        let swapped = p.point(lon: 43.191567, lat: 24.294928)
        XCTAssertNotEqual(correct.x, swapped.x, accuracy: 0.001)
    }

    // MARK: - Holes

    /// A HOLE MUST ACTUALLY BE A HOLE.
    ///
    /// Asserted by hit-testing under the even-odd rule rather than by
    /// counting path elements — an earlier version of this test counted
    /// `.move` elements and failed at 4 instead of 2, because closing a
    /// subpath inserts its own move. That count was measuring the path's
    /// internal representation, not the property anyone cares about.
    ///
    /// Filling each ring separately instead would paint the holes solid:
    /// four invented hectares of crop across the owner's real 32-hectare
    /// parcel 15655-19.
    func testHolesAreActuallyHoles() throws {
        let outer = square(lonFrom: 24.21, lonTo: 24.29, latFrom: 43.12, latTo: 43.18)
        let hole = square(lonFrom: 24.23, lonTo: 24.25, latFrom: 43.14, latTo: 43.16)
        let p = projection()
        let path = try XCTUnwrap(SchematicParcelMap.path(for: [outer, hole], with: p))

        // Dead centre of the hole, and a point inside the ring but outside it.
        let inHole = p.point(lon: 24.24, lat: 43.15)
        let inRing = p.point(lon: 24.22, lat: 43.13)

        XCTAssertTrue(path.contains(inRing, eoFill: true), "the field itself must be filled")
        XCTAssertFalse(path.contains(inHole, eoFill: true), "the hole must NOT be filled")

        // And the same point IS covered without even-odd — which is exactly
        // the bug this guards against.
        XCTAssertTrue(path.contains(inHole, eoFill: false),
                      "non-zero winding would paint the hole solid")
    }

    func testDegenerateRingIsDroppedNotDrawn() {
        let twoPoints = [[24.21, 43.12], [24.22, 43.13]]
        XCTAssertNil(SchematicParcelMap.path(for: [twoPoints], with: projection()))
    }

    // MARK: - Sown inference

    func testSownIsInferredFromCropAndIsNotAServerField() {
        XCTAssertTrue(parcel(crop: "Wheat").isSown)
        XCTAssertFalse(parcel(crop: nil).isSown)
        XCTAssertFalse(parcel(crop: "").isSown, "an empty crop is not a crop")
    }

    // MARK: - Helpers

    private func square(lonFrom: Double, lonTo: Double,
                        latFrom: Double, latTo: Double) -> [[Double]] {
        [[lonFrom, latFrom], [lonTo, latFrom], [lonTo, latTo], [lonFrom, latTo], [lonFrom, latFrom]]
    }

    private func parcel(crop: String?) -> Parcel {
        let cropJSON = crop.map { "\"\($0)\"" } ?? "null"
        let json = Data("""
        {"id":"p","name":"n","cropType":\(cropJSON),"areaHa":1,"geometry":null,
         "soilType":null,"cadastralId":null,"ekatte":null,"hasActiveLease":false}
        """.utf8)
        return try! JSONDecoder().decode(Parcel.self, from: json)
    }
}

enum BoundingBoxFixture {
    /// The owner's real farm bounds — the same numbers the projection's
    /// vectors were computed against, so both suites agree on the frame.
    static let pleven: BoundingBox = {
        let json = Data("[24.200137111155442, 43.107931901793236, 24.30476217650357, 43.19647081171462]".utf8)
        return try! JSONDecoder().decode(BoundingBox.self, from: json)
    }()
}
