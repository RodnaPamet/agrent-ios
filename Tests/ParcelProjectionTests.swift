import XCTest
import CoreGraphics
@testable import Agrent

/// Vectors computed from the FOUR REAL PARCELS on the `agrent` tenant, via
/// PostGIS `ST_PointOnSurface`, then reproduced independently by the session
/// building the renderer. Both derivations agree to within 0.1px.
///
/// They exist because the schematic map has no imagery behind it. Every failure
/// this file guards against renders a picture that still looks like a farm:
/// transposed axes, an unflipped y, a missing longitude correction and a
/// top-left anchor all produce well-formed polygons in the wrong place. There is
/// nothing on screen to notice any of them against — which is precisely what
/// made schematic-by-default worth testing rather than trusting.
final class ParcelProjectionTests: XCTestCase {

    /// The four parcels' real extent.
    private let bounds = ParcelProjection.Bounds(
        minLon: 24.200137111155442, minLat: 43.107931901793236,
        maxLon: 24.30476217650357,  maxLat: 43.19647081171462
    )
    private let size = CGSize(width: 390, height: 520)

    private func projection() -> ParcelProjection {
        ParcelProjection(bounds: bounds, size: size, padding: 16)
    }

    /// name -> (lon, lat, expected x, expected y)
    private let vectors: [(String, Double, Double, CGFloat, CGFloat)] = [
        ("15655-19", 24.20723958994037,  43.11167793380841, 40.3, 450.1),
        ("15655-3",  24.201674620689705, 43.11575953849743, 21.3, 430.9),
        ("20688.13", 24.294928474600653, 43.19156728759939, 340.4, 75.4),
        ("20688.80", 24.30169866116787,  43.1412995616474,  363.5, 311.1),
    ]

    func testProjectsTheFourRealParcelsToTheirComputedPoints() {
        let p = projection()
        for (name, lon, lat, ex, ey) in vectors {
            let got = p.point(lon: lon, lat: lat)
            XCTAssertEqual(got.x, ex, accuracy: 0.15, "\(name) x")
            XCTAssertEqual(got.y, ey, accuracy: 0.15, "\(name) y")
        }
    }

    /// North must map UP. A missing y-flip still fills the view — the map looks
    /// fine and the farm is mirrored. Nothing on a schematic render catches it.
    func testNorthIsUp() {
        let p = projection()
        let north = p.point(lon: 24.294928474600653, lat: 43.19156728759939) // 20688.13
        let mid   = p.point(lon: 24.30169866116787,  lat: 43.1412995616474)  // 20688.80
        let south = p.point(lon: 24.20723958994037,  lat: 43.11167793380841) // 15655-19
        XCTAssertLessThan(north.y, mid.y, "the northernmost parcel must have the smallest y")
        XCTAssertLessThan(mid.y, south.y, "y must increase going south")
    }

    /// East must map RIGHT — a transpose is a different failure from an unflipped
    /// y, so it needs its own assertion.
    func testEastIsRight() {
        let p = projection()
        let east = p.point(lon: 24.30169866116787,  lat: 43.1412995616474)  // 20688.80
        let west = p.point(lon: 24.201674620689705, lat: 43.11575953849743) // 15655-3
        XCTAssertGreaterThan(east.x, west.x, "the easternmost parcel must have the largest x")
    }

    /// The content is CENTRED on the slack axis, not pinned to the padding.
    ///
    /// Its own test because top-left anchoring reproduces every x above exactly
    /// — x has zero slack on these bounds — while putting y 36.4px out. A suite
    /// that only checked the vectors' x would pass on the wrong implementation.
    func testContentIsCentredOnTheSlackAxis() {
        let p = projection()
        XCTAssertEqual(p.contentOrigin.x, 16.0, accuracy: 0.15, "x has no slack here")
        XCTAssertEqual(p.contentOrigin.y, 52.4, accuracy: 0.15, "y slack is split, not dropped at the top")
        XCTAssertNotEqual(p.contentOrigin.y, p.padding, "padding-anchored y is the bug this guards")

        let slackY = (size.height - 2 * p.padding) - p.contentSize.height
        XCTAssertEqual(p.contentOrigin.y - p.padding, slackY / 2, accuracy: 0.15)
    }

    /// The longitude correction, and what dropping it costs.
    func testLongitudeIsScaledByCosineOfMeanLatitude() {
        let p = projection()
        XCTAssertEqual(p.longitudeCorrection, 0.72954, accuracy: 0.00001)

        // Uncorrected, the uniform scale would be 3421.7 rather than 4690.3, and
        // the farm would render at 73% of its true height.
        let uncorrected = (size.width - 32) / CGFloat(bounds.maxLon - bounds.minLon)
        XCTAssertEqual(p.scale, 4690.3, accuracy: 1.0)
        XCTAssertEqual(uncorrected, 3421.7, accuracy: 1.0)
        XCTAssertEqual(p.contentSize.height / (CGFloat(bounds.maxLat - bounds.minLat) * uncorrected),
                       1 / 0.72954, accuracy: 0.01,
                       "dropping the correction flattens the map by cos(meanLat)")
    }

    /// The scale is one number for both axes. Per-axis scales would fill the box
    /// exactly and distort every parcel doing it.
    func testScaleIsUniformSoShapesSurvive() {
        let p = projection()
        let degLon = 0.001, degLat = 0.001
        let a = p.point(lon: bounds.minLon,          lat: bounds.maxLat)
        let b = p.point(lon: bounds.minLon + degLon, lat: bounds.maxLat)
        let c = p.point(lon: bounds.minLon,          lat: bounds.maxLat - degLat)
        let xPerCorrectedDegree = (b.x - a.x) / CGFloat(degLon * p.longitudeCorrection)
        let yPerDegree = (c.y - a.y) / CGFloat(degLat)
        XCTAssertEqual(xPerCorrectedDegree, yPerDegree, accuracy: 0.5)
    }

    /// A malformed `bounds` must refuse rather than draw something confident.
    func testWireBoundsRejectMalformedInput() {
        XCTAssertNil(ParcelProjection.Bounds(wire: [24.2, 43.1, 24.3]))
        XCTAssertNil(ParcelProjection.Bounds(wire: [24.3, 43.1, 24.2, 43.2]), "maxLon < minLon")
        XCTAssertNil(ParcelProjection.Bounds(wire: [24.2, 43.2, 24.3, 43.1]), "maxLat < minLat")
        XCTAssertNil(ParcelProjection.Bounds(wire: [.nan, 43.1, 24.3, 43.2]))
        XCTAssertNotNil(ParcelProjection.Bounds(wire: [24.2, 43.1, 24.3, 43.2]))
    }

    /// One parcel, or several at one point, has zero span. It must centre rather
    /// than divide by zero — a crash in a field is worse than a dot.
    func testDegenerateBoundsDoNotDivideByZero() {
        let point = ParcelProjection.Bounds(minLon: 24.2, minLat: 43.1, maxLon: 24.2, maxLat: 43.1)
        let p = ParcelProjection(bounds: point, size: size, padding: 16)
        let got = p.point(lon: 24.2, lat: 43.1)
        XCTAssertTrue(got.x.isFinite && got.y.isFinite)
        XCTAssertEqual(got.x, size.width / 2, accuracy: 0.15)
        XCTAssertEqual(got.y, size.height / 2, accuracy: 0.15)
    }
}
