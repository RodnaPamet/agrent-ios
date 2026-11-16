import CoreLocation
import XCTest
@testable import Agrent

/// «Времето» for where the map is looking (#642, owner 2026-11-16).
/// Synthetic squares, no real geometry.
final class WeatherPointTests: XCTestCase {

    private func ring(lon: Double, lat: Double, side: Double) -> [[Double]] {
        [[lon, lat], [lon + side, lat], [lon + side, lat + side], [lon, lat + side], [lon, lat]]
    }

    private func parcel(_ name: String, _ rings: [[[Double]]]) -> Parcel {
        Parcel(id: name, name: name, cropType: nil, areaHa: nil,
               geometry: ParcelGeometry(type: "MultiPolygon", coordinates: [rings]),
               soilType: nil, cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil)
    }

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func testAPointInsideAndOutsideAndInAHole() throws {
        let field = parcel("Нива 1", [ring(lon: 25, lat: 42, side: 1), ring(lon: 25.4, lat: 42.4, side: 0.2)])
        let geometry = try XCTUnwrap(field.geometry)
        XCTAssertTrue(geometry.contains(at(42.1, 25.1)))
        XCTAssertFalse(geometry.contains(at(42.5, 25.5)), "in the hole")
        XCTAssertFalse(geometry.contains(at(43.5, 25.5)), "outside")
    }

    /// Named by the parcel under the map's centre, else as the centre.
    func testThePlaceIsNamedByWhatIsUnderTheCentre() {
        let parcels = [parcel("Нива 1", [ring(lon: 25, lat: 42, side: 1)]),
                       parcel("Нива 2", [ring(lon: 27, lat: 42, side: 1)])]
        XCTAssertEqual(WeatherPoint.place(at: at(42.5, 27.5), parcels: parcels, block: "Блок А"), "Нива 2, Блок А")
        XCTAssertEqual(WeatherPoint.place(at: at(42.5, 26.5), parcels: parcels, block: "Блок А"),
                       "Блок А, центъра на картата")
    }
}
