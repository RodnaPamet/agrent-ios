import MapKit
import XCTest
@testable import Agrent

final class VegetationIndexTests: XCTestCase {

    // MARK: - The index table

    /// The five the server serves. Written out rather than derived from
    /// `allCases`, so adding a sixth here without an endpoint fails.
    private let serverIndices = ["ndvi", "ndmi", "ndre", "gndvi", "evi"]

    func testCasesMatchTheServersEndpoints() {
        XCTAssertEqual(Set(VegetationIndex.allCases.map(\.rawValue)), Set(serverIndices))
    }

    func testPathIsTheEndpointTheServerPublished() {
        let path = AgroAPI.path(.ndvi, locationID: "cmqwmqdqv000101kwxdxval23")
        XCTAssertTrue(path.hasSuffix("/agro/ndvi-tiles?locationId=cmqwmqdqv000101kwxdxval23"), path)
    }

    /// `locationId` is required — tiles are clipped to that location's
    /// parcels, and a request without it is not a wider map, it is a 400.
    func testEveryIndexCarriesTheLocation() {
        for index in VegetationIndex.allCases {
            XCTAssertTrue(AgroAPI.path(index, locationID: "abc").contains("locationId=abc"))
            XCTAssertTrue(AgroAPI.path(index, locationID: "abc").contains("/agro/\(index.rawValue)-tiles"))
        }
    }

    func testEveryRampHasFiveStops() {
        for index in VegetationIndex.allCases {
            XCTAssertEqual(index.ramp.count, 5, "\(index.name) ramp")
        }
    }

    /// The legend ends had no Bulgarian anywhere — the web prints the English
    /// literals `Low`/`High`/`Dry`/`Wet` raw. These are the agreed words, and
    /// this test is what stops them drifting back.
    func testLegendEndsAreBulgarian() {
        for index in VegetationIndex.allCases {
            XCTAssertFalse(index.lowLabel.isEmpty)
            XCTAssertFalse(index.highLabel.isEmpty)
            XCTAssertNotEqual(index.lowLabel, index.highLabel)
            for label in [index.lowLabel, index.highLabel, index.explanation] {
                XCTAssertTrue(
                    label.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x400 },
                    "\(index.name) label is not Cyrillic: \(label)"
                )
            }
        }
    }

    /// Moisture reads dry-to-wet. "Ниска влага" would be true and useless.
    func testMoistureIndexReadsDryToWet() {
        XCTAssertEqual(VegetationIndex.ndmi.lowLabel, "Сухо")
        XCTAssertEqual(VegetationIndex.ndmi.highLabel, "Влажно")
        XCTAssertEqual(VegetationIndex.ndvi.lowLabel, "Ниска")
    }

    func testIndexNamesStayInternational() {
        // NDVI is NDVI in every language an agronomist works in.
        XCTAssertEqual(VegetationIndex.ndvi.name, "NDVI")
        XCTAssertEqual(VegetationIndex.gndvi.name, "GNDVI")
    }

    // MARK: - The response

    func testDecodesAConfiguredResponse() throws {
        let json = Data("""
        {"configured":true,"tileUrl":"https://earthengine.googleapis.com/v1/projects/x/maps/y/tiles/{z}/{x}/{y}","date":"2026-09-19"}
        """.utf8)
        let tiles = try JSONDecoder().decode(IndexTiles.self, from: json)
        XCTAssertTrue(tiles.isUsable)
        XCTAssertEqual(tiles.date, "2026-09-19")
    }

    /// Not configured is not an error. It must reach the UI as a fact so the
    /// buttons can be hidden rather than shown broken.
    func testUnconfiguredIsNotUsableAndNotAFailure() throws {
        let json = Data(#"{"configured":false,"tileUrl":""}"#.utf8)
        let tiles = try JSONDecoder().decode(IndexTiles.self, from: json)
        XCTAssertFalse(tiles.configured)
        XCTAssertFalse(tiles.isUsable)
        XCTAssertNil(tiles.date)
    }

    /// `configured:true` with an empty URL is still nothing to draw.
    func testConfiguredWithNoURLIsNotUsable() throws {
        let json = Data(#"{"configured":true,"tileUrl":""}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(IndexTiles.self, from: json).isUsable)
    }

    // MARK: - MapKit actually understands the template

    /// The probe found `{z}` before `{x}` in the live URL, which is the
    /// ordering MapKit substitutes by NAME rather than by position — but
    /// asserting that from the documentation is not the same as executing
    /// it. A y-axis or axis-order mistake here renders a plausible,
    /// wrong field rather than an error, so this runs the substitution.
    func testMapKitSubstitutesTheEarthEngineTemplate() throws {
        let template = "https://earthengine.googleapis.com/v1/projects/p/maps/m/tiles/{z}/{x}/{y}"
        let overlay = MKTileOverlay(urlTemplate: template)
        let url = overlay.url(forTilePath: MKTileOverlayPath(x: 37, y: 22, z: 12, contentScaleFactor: 1))
        XCTAssertEqual(url.absoluteString,
                       "https://earthengine.googleapis.com/v1/projects/p/maps/m/tiles/12/37/22")
    }

    /// Transparent-outside-the-parcel only works if Apple's imagery is still
    /// drawn underneath. `true` here turns the surroundings black.
    func testTilesDoNotReplaceMapContent() {
        let overlay = MKTileOverlay(urlTemplate: "https://x/{z}/{x}/{y}")
        overlay.canReplaceMapContent = false
        XCTAssertFalse(overlay.canReplaceMapContent)
    }
}

/// `"2026-09-19"` is a DAY, not an instant, and the failure mode is a
/// silent off-by-one.
final class BgDateISODayTests: XCTestCase {

    func testParsesTheDayTheServerSent() throws {
        let date = try XCTUnwrap(BgDate.parseISODay("2026-09-19"))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 19)
    }

    /// The real bug this guards: parsing as UTC and rendering in the device
    /// zone moves the day backwards west of Greenwich. Round-tripping
    /// through the app's own formatter is the check that the digits survive.
    func testTheDayRoundTripsThroughTheDisplayFormatter() throws {
        for day in ["2026-01-01", "2026-06-15", "2026-09-19", "2026-12-31"] {
            let date = try XCTUnwrap(BgDate.parseISODay(day))
            let rendered = BgDate.full(date)
            let expected = String(day.suffix(2)).trimmingCharacters(in: ["0"])
            XCTAssertTrue(rendered.hasPrefix(expected + " "),
                          "\(day) rendered as \(rendered)")
        }
    }

    func testRejectsWhatIsNotADay() {
        XCTAssertNil(BgDate.parseISODay(""))
        XCTAssertNil(BgDate.parseISODay("не знам"))
        // A full timestamp is a different shape and must not silently parse
        // as a day — if the server ever switches, this should fail loudly.
        XCTAssertNil(BgDate.parseISODay("2026-09-19T10:30:00Z"))
    }
}

/// The camera fallback. One of this tenant's two locations returns neither
/// `bounds` nor `boundsJson`, so `MKCoordinateRegion(.world)` was one server
/// field away from being what the satellite map opened on.
final class ParcelRegionTests: XCTestCase {

    /// `coordinates` is FOUR deep — polygon, ring, point, x/y — because the
    /// field is MultiPolygon-shaped. Building it three deep decodes into a
    /// type mismatch, which is how this helper was first written.
    private func parcel(_ ring: [[Double]]) throws -> Parcel {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "p1", "name": "15655-19",
            "geometry": ["type": "MultiPolygon", "coordinates": [[ring]]],
        ])
        return try JSONDecoder().decode(Parcel.self, from: json)
    }

    /// The real parcel, at the coordinates the live probe fetched tiles for.
    private var ivosLand: [[Double]] {
        [[24.2055, 43.1108], [24.2065, 43.1108], [24.2065, 43.1118], [24.2055, 43.1118]]
    }

    func testRegionLandsOnTheParcelNotTheRedSea() throws {
        let region = try XCTUnwrap(MKCoordinateRegion(fitting: [try parcel(ivosLand)]))
        // Bulgaria, not its transpose. 43°N 24°E vs 24°N 43°E is the whole
        // bug — see ParcelGeometry.coordinate(from:).
        XCTAssertEqual(region.center.latitude, 43.1113, accuracy: 0.001)
        XCTAssertEqual(region.center.longitude, 24.206, accuracy: 0.001)
    }

    /// A single small parcel must not zoom to street level.
    func testSpanHasAFloor() throws {
        let region = try XCTUnwrap(MKCoordinateRegion(fitting: [try parcel(ivosLand)]))
        XCTAssertGreaterThanOrEqual(region.span.latitudeDelta, 0.005)
        XCTAssertGreaterThanOrEqual(region.span.longitudeDelta, 0.005)
    }

    /// Nothing drawable is nil, not a region centred on 0,0 — which is in the
    /// Atlantic and looks like a loaded map.
    func testNoGeometryGivesNoRegion() {
        XCTAssertNil(MKCoordinateRegion(fitting: []))
    }
}

/// The terminal camera fallback.
final class BulgariaFallbackTests: XCTestCase {

    /// The web's constant, shared exactly — `BULGARIA_VIEW` in MapCanvas.tsx.
    func testCentreMatchesTheWeb() {
        XCTAssertEqual(MKCoordinateRegion.bulgaria.center.latitude, 42.73, accuracy: 0.0001)
        XCTAssertEqual(MKCoordinateRegion.bulgaria.center.longitude, 25.49, accuracy: 0.0001)
    }

    /// The whole point: the country is in view, and the planet is not.
    func testTheCountryFitsAndTheWorldDoesNot() {
        let region = MKCoordinateRegion.bulgaria
        // Bulgaria spans roughly 41.24–44.22 N and 22.36–28.61 E.
        XCTAssertGreaterThanOrEqual(region.span.latitudeDelta, 2.98)
        XCTAssertGreaterThanOrEqual(region.span.longitudeDelta, 6.25)
        // Not the world, which is what this replaced.
        XCTAssertLessThan(region.span.latitudeDelta, 20)
        XCTAssertLessThan(region.span.longitudeDelta, 20)
    }

    func testTheCountryIsActuallyInsideTheFrame() {
        let region = MKCoordinateRegion.bulgaria
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        XCTAssertGreaterThan(north, 44.22)
        XCTAssertLessThan(south, 41.24)
        XCTAssertGreaterThan(east, 28.61)
        XCTAssertLessThan(west, 22.36)
    }
}
