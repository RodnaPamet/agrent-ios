import XCTest
@testable import Agrent

/// «Вятър и налягане» (owner, 2026-11-06): the Open-Meteo request, its
/// decoding, and the isobars and pressure centres drawn from it. Nothing
/// here calls Open-Meteo.
final class WindFieldTests: XCTestCase {

    // MARK: - The request

    /// One request for the whole grid, every place comma-separated, in m/s,
    /// 48 hours; the same for every farm, so nothing of the farm is in it.
    func testOneRequestAsksForTheWholeGrid() throws {
        let url = OpenMeteoAPI.url()
        XCTAssertEqual(url.host, "api.open-meteo.com", "the free tier, by the owner's choice")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let places = WindGrid.latitudes.count * WindGrid.longitudes.count
        XCTAssertEqual(places, 170)
        XCTAssertEqual(value("latitude")?.split(separator: ",").count, places)
        XCTAssertEqual(value("longitude")?.split(separator: ",").count, places)
        XCTAssertEqual(value("hourly"), "wind_speed_10m,wind_direction_10m,pressure_msl")
        XCTAssertEqual(value("wind_speed_unit"), "ms")
        XCTAssertEqual(value("forecast_hours"), "48")
        XCTAssertNil(value("apikey"))
        XCTAssertEqual(OpenMeteoAPI.url(apiKey: "k").host, "customer-api.open-meteo.com", "the paid switch")
    }

    /// Open-Meteo's array, place by place in the order asked, becomes the
    /// grid; a missing value takes the hour before's.
    func testTheAnswerBecomesTheGrid() throws {
        let places = WindGrid.latitudes.count * WindGrid.longitudes.count
        // Built in steps: as one interpolated literal in a closure it was
        // more than CI's compiler would type-check in time.
        var body: [String] = []
        for i in 0..<places {
            let wind: String = String(i % 7)
            let pressure: String = i == 0 ? "null" : "1011"
            var place: String = #"{"hourly":{"time":["2026-11-06T18:00","2026-11-06T19:00"],"#
            place += #""wind_speed_10m":["# + wind + #",3.5],"wind_direction_10m":[200,210],"#
            place += #""pressure_msl":[1010,"# + pressure + "]}}"
            body.append(place)
        }
        let field = try OpenMeteoAPI.decode(Data("[\(body.joined(separator: ","))]".utf8))
        XCTAssertEqual(field.hours.count, 2)
        XCTAssertEqual(field.windMS[0][0][1], 1, "place 1 is row 0, column 1")
        XCTAssertEqual(field.windMS[0][1][0], Double(WindGrid.longitudes.count % 7), "the next row starts after a whole row")
        XCTAssertEqual(field.pressure[1][0][0], 1010, "a gap takes the hour before's")
        XCTAssertEqual(field.points(at: 1).count, places)
        XCTAssertEqual(OpenMeteoAPI.parseHour("2026-11-06T18:00"), BgDate.parseInstant("2026-11-06T18:00:00Z"))
    }

    func testAShortAnswerIsRefused() {
        XCTAssertThrowsError(try OpenMeteoAPI.decode(Data(#"[]"#.utf8)))
    }

    // MARK: - Isobars and centres

    /// A bowl: pressure rising away from the middle. Its isobars are rings
    /// round the low, and the low is found where it is.
    func testABowlHasRingsAndALowInTheMiddle() {
        let lats: [Double] = (0..<9).map { 40 + Double($0) * 0.5 }
        let lons: [Double] = (0..<9).map { 22 + Double($0) * 0.5 }
        // In steps: as one nested closure, CI's compiler gave up on it.
        var grid: [[Double]] = []
        for lat in lats {
            var row: [Double] = []
            for lon in lons {
                let dy: Double = lat - 42, dx: Double = lon - 24
                row.append(1000 + (dy * dy + dx * dx) * 2)
            }
            grid.append(row)
        }
        let centres = PressureAnalysis.centres(grid, latitudes: lats, longitudes: lons)
        XCTAssertEqual(centres.count, 1)
        XCTAssertEqual(centres.first?.kind, .low)
        XCTAssertEqual(centres.first?.latitude, 42)
        XCTAssertEqual(centres.first?.longitude, 24)
        XCTAssertEqual(centres.first?.hPa, 1000)

        let isobars = PressureAnalysis.isobars(grid, latitudes: lats, longitudes: lons)
        let ring = isobars.first { $0.hPa == 1002 }
        XCTAssertNotNil(ring, "a ring at 1002")
        // Closed: the joined line ends where it starts.
        if let ring, let first = ring.path.first, let last = ring.path.last {
            XCTAssertEqual(first.latitude, last.latitude, accuracy: 1e-6)
            XCTAssertEqual(first.longitude, last.longitude, accuracy: 1e-6)
            XCTAssertGreaterThan(ring.path.count, 4)
        }
        XCTAssertTrue(isobars.allSatisfy { $0.hPa.truncatingRemainder(dividingBy: 2) == 0 }, "every 2 hPa")
    }

    /// A flat field, or a gentle slope, marks no centre: no false cyclones.
    func testAFlatFieldMarksNothing() {
        let lats = [40.0, 40.5, 41.0, 41.5], lons = [22.0, 22.5, 23.0, 23.5]
        let flat = lats.map { _ in lons.map { _ in 1013.0 } }
        XCTAssertEqual(PressureAnalysis.centres(flat, latitudes: lats, longitudes: lons), [])
        XCTAssertEqual(PressureAnalysis.isobars(flat, latitudes: lats, longitudes: lons).count, 0)
        let slope: [[Double]] = lats.map { lat in lons.map { lon in 1000 + lat + lon } }
        XCTAssertEqual(PressureAnalysis.centres(slope, latitudes: lats, longitudes: lons), [])
    }

    /// The seam's fixture is a low crossing the country, so the screenshot
    /// shows a «Н»; and a unit run uses the real source, not the fixture.
    func testTheFixtureHasALowAndTheAppUsesOpenMeteo() async throws {
        let field = try await FixtureWindFieldSource().field()
        XCTAssertEqual(field.hours.count, 48)
        let centres = PressureAnalysis.centres(field.pressure[24], latitudes: field.latitudes, longitudes: field.longitudes)
        XCTAssertTrue(centres.contains { $0.kind == .low }, "no low in the fixture at +24 h")
        XCTAssertTrue(WindFieldSources.current is OpenMeteoWindSource)
    }

    func testTheBandsAndTheHour() {
        XCTAssertEqual(WindMapWords.bands.map(\.label), ["до 4 м/с", "4–8", "8–12", "над 12"])
        XCTAssertEqual(WeatherWords.compass(225), "ЮЗ")
        XCTAssertEqual(WeatherWords.pressure(1013.4), "1013 hPa")
        let centre = PressureAnalysis.Centre(kind: .low, latitude: 42, longitude: 24, hPa: 1002)
        XCTAssertEqual(WindMapWords.centreSpoken(centre), "Ниско налягане, циклон 1002 hPa")
    }

    // MARK: - The streaks

    private func uniform(speed: Double, from: Double) -> WindField {
        let lats = [42.0, 42.5, 43.0], lons = [24.0, 24.5, 25.0]
        let grid = lats.map { _ in lons.map { _ in speed } }
        let dir = lats.map { _ in lons.map { _ in from } }
        return WindField(hours: [Date()], latitudes: lats, longitudes: lons,
                         windMS: [grid], windFrom: [dir], pressure: [grid])
    }

    /// A west wind blows east (u > 0); a north wind blows south (v < 0).
    func testTheWindBlowsAwayFromWhereItComesFrom() throws {
        let west = try XCTUnwrap(WindVectors(uniform(speed: 10, from: 270), hour: 0).at(latitude: 42.2, longitude: 24.3))
        XCTAssertEqual(west.u, 10, accuracy: 1e-9)
        XCTAssertEqual(west.v, 0, accuracy: 1e-9)
        let north = try XCTUnwrap(WindVectors(uniform(speed: 5, from: 0), hour: 0).at(latitude: 42.9, longitude: 24.9))
        XCTAssertEqual(north.u, 0, accuracy: 1e-9)
        XCTAssertEqual(north.v, -5, accuracy: 1e-9)
        XCTAssertNil(WindVectors(uniform(speed: 5, from: 0), hour: 0).at(latitude: 41.9, longitude: 24.5), "outside the grid")
        XCTAssertNil(WindVectors(uniform(speed: 5, from: 0), hour: 3).at(latitude: 42.5, longitude: 24.5), "no such hour")
    }

    /// Between grid places the wind is mixed from the four corners.
    func testTheWindIsInterpolatedBetweenPlaces() throws {
        let lats = [42.0, 43.0], lons = [24.0, 25.0]
        let field = WindField(hours: [Date()], latitudes: lats, longitudes: lons,
                              windMS: [[[0, 10], [0, 10]]], windFrom: [[[270, 270], [270, 270]]],
                              pressure: [[[1013, 1013], [1013, 1013]]])
        let middle = try XCTUnwrap(WindVectors(field, hour: 0).at(latitude: 42.5, longitude: 24.5))
        XCTAssertEqual(middle.u, 5, accuracy: 1e-9)
    }

    /// The map's region onto the canvas: the centre in the middle, the
    /// west edge at 0, and north up.
    func testTheProjectionFollowsTheMap() {
        let projection = WindProjection(region: WindMapView.bulgaria, size: CGSize(width: 400, height: 800))
        let centre = projection.point(latitude: 42.75, longitude: 25.5)
        XCTAssertEqual(centre.x, 200, accuracy: 0.001)
        XCTAssertEqual(centre.y, 400, accuracy: 20, "Mercator puts the middle latitude near, not at, half height")
        XCTAssertEqual(projection.point(latitude: 42.75, longitude: 25.5 - 4.2).x, 0, accuracy: 0.001)
        XCTAssertLessThan(projection.point(latitude: 44, longitude: 25).y, projection.point(latitude: 42, longitude: 25).y)
    }
}

