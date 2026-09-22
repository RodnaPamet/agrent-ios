import MapKit
import XCTest
@testable import Agrent

/// Tapping a field on the satellite map.
///
/// The hit-test itself needs a live `MKMapView`, but the mechanism it relies
/// on does not: whether `MKPolygonRenderer` builds interior rings into its
/// path such that an even-odd test treats a hole as outside. That is the
/// assumption the whole thing rests on, it is the one I would otherwise be
/// taking from documentation, and it is executable.
final class ParcelTapTests: XCTestCase {

    /// A 1° square with a hole through the middle of it, at the owner's
    /// latitude so the projection is the one really used.
    private func squareWithHole() -> MKPolygon {
        let outer = [
            CLLocationCoordinate2D(latitude: 43.0, longitude: 24.0),
            CLLocationCoordinate2D(latitude: 43.0, longitude: 25.0),
            CLLocationCoordinate2D(latitude: 44.0, longitude: 25.0),
            CLLocationCoordinate2D(latitude: 44.0, longitude: 24.0),
        ]
        let hole = [
            CLLocationCoordinate2D(latitude: 43.4, longitude: 24.4),
            CLLocationCoordinate2D(latitude: 43.4, longitude: 24.6),
            CLLocationCoordinate2D(latitude: 43.6, longitude: 24.6),
            CLLocationCoordinate2D(latitude: 43.6, longitude: 24.4),
        ]
        return MKPolygon(
            coordinates: outer, count: outer.count,
            interiorPolygons: [MKPolygon(coordinates: hole, count: hole.count)]
        )
    }

    private func contains(_ polygon: MKPolygon, _ coordinate: CLLocationCoordinate2D) -> Bool {
        let renderer = MKPolygonRenderer(polygon: polygon)
        renderer.createPath()
        guard let path = renderer.path else { return false }
        return path.contains(renderer.point(for: MKMapPoint(coordinate)), using: .evenOdd)
    }

    func testAPointInTheFieldHits() {
        XCTAssertTrue(contains(squareWithHole(),
            CLLocationCoordinate2D(latitude: 43.1, longitude: 24.1)))
    }

    /// The reason even-odd is spelled out. `15655-19` is one polygon with
    /// five rings — four holes — across 32 hectares, so tapping a hole is
    /// something an operator will really do, and it should select nothing
    /// rather than the field around it.
    func testAPointInAHoleMisses() {
        XCTAssertFalse(contains(squareWithHole(),
            CLLocationCoordinate2D(latitude: 43.5, longitude: 24.5)))
    }

    func testAPointOutsideMisses() {
        XCTAssertFalse(contains(squareWithHole(),
            CLLocationCoordinate2D(latitude: 42.0, longitude: 23.0)))
    }

    /// Without the hole, the same centre point is inside — which proves the
    /// miss above comes from the hole and not from the projection or the
    /// path being empty. A negative result from a probe that has never
    /// produced a positive proves nothing.
    func testTheSamePointHitsWhenTheHoleIsRemoved() {
        let outer = [
            CLLocationCoordinate2D(latitude: 43.0, longitude: 24.0),
            CLLocationCoordinate2D(latitude: 43.0, longitude: 25.0),
            CLLocationCoordinate2D(latitude: 44.0, longitude: 25.0),
            CLLocationCoordinate2D(latitude: 44.0, longitude: 24.0),
        ]
        XCTAssertTrue(contains(MKPolygon(coordinates: outer, count: outer.count),
            CLLocationCoordinate2D(latitude: 43.5, longitude: 24.5)))
    }

    /// `boundingMapRect` is the cheap pre-filter before the path test. It is
    /// a superset — a point inside the box can still be outside the shape —
    /// and using it ALONE is the mistake it would be easy to make.
    func testTheBoundingBoxIsASupersetNotTheAnswer() {
        let polygon = squareWithHole()
        let inHole = MKMapPoint(CLLocationCoordinate2D(latitude: 43.5, longitude: 24.5))
        XCTAssertTrue(polygon.boundingMapRect.contains(inHole),
                      "the hole is inside the bounding box")
        XCTAssertFalse(contains(polygon, CLLocationCoordinate2D(latitude: 43.5, longitude: 24.5)),
                       "but outside the shape")
    }
}
