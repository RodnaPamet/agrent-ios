import CoreLocation
import MapKit
import XCTest
@testable import Agrent

/// The «you are here» dot (#492): which parcel the phone stands in, only on a
/// fix that can tell, and what the system's answer means to the button.
/// Nothing here asks for the location or starts the GPS.
final class DeviceLocationTests: XCTestCase {

    /// A synthetic square, `side` degrees wide, south-west corner at (lon, lat).
    private func square(lon: Double, lat: Double, side: Double) -> ParcelGeometry {
        let ring = [[lon, lat], [lon + side, lat], [lon + side, lat + side], [lon, lat + side], [lon, lat]]
        return ParcelGeometry(type: "MultiPolygon", coordinates: [[ring]])
    }

    private func parcel(_ id: String, ha: Double?, geometry: ParcelGeometry?) -> Parcel {
        Parcel(id: id, name: "Нива \(id)", cropType: nil, areaHa: ha, geometry: geometry,
               soilType: nil, cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil)
    }

    private func fix(lat: Double, lon: Double, accuracy: CLLocationAccuracy) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: Date())
    }

    private lazy var parcels = [
        parcel("big", ha: 40, geometry: square(lon: 24.0, lat: 42.0, side: 0.02)),
        parcel("small", ha: 2, geometry: square(lon: 24.005, lat: 42.005, side: 0.005)),
        parcel("none", ha: 1, geometry: nil),
    ]

    /// Inside a field finds it, the smaller where two overlap, as a tap does;
    /// off every field, nothing.
    func testThePositionFindsTheParcelItIsIn() {
        let outlines = StandingIn.outlines(parcels)
        XCTAssertEqual(StandingIn.parcel(at: fix(lat: 42.007, lon: 24.007, accuracy: 5),
                                         in: parcels, outlines: outlines)?.id, "small")
        XCTAssertEqual(StandingIn.parcel(at: fix(lat: 42.018, lon: 24.018, accuracy: 5),
                                         in: parcels, outlines: outlines)?.id, "big")
        XCTAssertNil(StandingIn.parcel(at: fix(lat: 43, lon: 25, accuracy: 5), in: parcels, outlines: outlines))
        XCTAssertNil(StandingIn.parcel(at: nil, in: parcels, outlines: outlines))
        XCTAssertEqual(StandingIn.sentence(parcels[1]), "Намирате се в «Нива small»")
    }

    /// A rough fix puts nobody in a parcel: it can't say which side of a
    /// boundary it is on. An invalid one (negative accuracy) neither.
    func testARoughFixSaysNothing() {
        let outlines = StandingIn.outlines(parcels)
        let limit = DeviceLocation.usableAccuracy
        XCTAssertNotNil(StandingIn.parcel(at: fix(lat: 42.018, lon: 24.018, accuracy: limit),
                                          in: parcels, outlines: outlines))
        XCTAssertNil(StandingIn.parcel(at: fix(lat: 42.018, lon: 24.018, accuracy: limit + 1),
                                       in: parcels, outlines: outlines))
        XCTAssertNil(StandingIn.parcel(at: fix(lat: 42.018, lon: 24.018, accuracy: -1),
                                       in: parcels, outlines: outlines))
    }

    /// What the system's answer means to the button: ask, centre, or say
    /// where the setting is. Restricted (parental controls, a managed phone)
    /// is a refusal the person can't undo here, so it is told the same way.
    func testTheSystemsAnswerToTheButton() {
        XCTAssertEqual(DeviceLocation.access(.notDetermined), .notAsked)
        XCTAssertEqual(DeviceLocation.access(.authorizedWhenInUse), .allowed)
        XCTAssertEqual(DeviceLocation.access(.authorizedAlways), .allowed)
        XCTAssertEqual(DeviceLocation.access(.denied), .refused)
        XCTAssertEqual(DeviceLocation.access(.restricted), .refused)
    }

    /// 400 m across, centred on the phone.
    func testCentringFramesTheFieldAroundThePhone() {
        let here = CLLocationCoordinate2D(latitude: 42.5, longitude: 25.1)
        let region = MKCoordinateRegion.around(here)
        XCTAssertEqual(region.center.latitude, 42.5, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, 25.1, accuracy: 1e-9)
        XCTAssertEqual(region.span.latitudeDelta * 111_000, 400, accuracy: 10)
    }
}
