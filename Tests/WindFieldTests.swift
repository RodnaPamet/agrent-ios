import MapKit
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
        XCTAssertEqual(value("hourly"), "wind_speed_10m,wind_direction_10m,pressure_msl,cloud_cover,precipitation")
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



    /// The seam's fixture is a low crossing the country, so the screenshot
    /// shows a «Н»; and a unit run uses the real source, not the fixture.
    func testTheFixtureHasALowAndTheAppUsesOpenMeteo() async throws {
        let field = try await FixtureWindFieldSource().field()
        XCTAssertEqual(field.hours.count, 48)
        XCTAssertLessThan(field.pressure[24].joined().min() ?? 9999, 1004, "a low in the fixture at +24 h")
        XCTAssertTrue(WindFieldSources.current is OpenMeteoWindSource)
    }

    func testTheBandsAndTheWords() {
        XCTAssertEqual(WindBands.bands.map(\.label), ["до 4 м/с", "4–8", "8–12", "над 12"])
        XCTAssertEqual(WeatherWords.compass(225), "ЮЗ")
        XCTAssertEqual(WeatherWords.pressure(1013.4), "1013 hPa")
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
        let projection = WindProjection(region: WindGrid.bulgaria, size: CGSize(width: 400, height: 800))
        let centre = projection.point(latitude: 42.75, longitude: 25.5)
        XCTAssertEqual(centre.x, 200, accuracy: 0.001)
        XCTAssertEqual(centre.y, 400, accuracy: 20, "Mercator puts the middle latitude near, not at, half height")
        XCTAssertEqual(projection.point(latitude: 42.75, longitude: 25.5 - 4.2).x, 0, accuracy: 0.001)
        XCTAssertLessThan(projection.point(latitude: 44, longitude: 25).y, projection.point(latitude: 42, longitude: 25).y)
    }

    // MARK: - Where streaks are born (owner, 2026-11-07)


    /// A block's map, about a degree across.
    private static func block(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                           span: MKCoordinateSpan(latitudeDelta: 1.1, longitudeDelta: 1.0))
    }

    /// Streaks are born where the map looks, within the grid; the whole grid
    /// when the view is off it.
    func testStreaksAreBornInView() {
        let grid: WindParticles.Box = (40.5, 45.0, 21.5, 29.5)
        let view = WindParticles.area(Self.block(latitude: 43.2, longitude: 24.4), within: grid)
        XCTAssertEqual(view.south, 43.2 - 0.55, accuracy: 1e-9)
        XCTAssertEqual(view.east, 24.4 + 0.5, accuracy: 1e-9)
        let edge = WindParticles.area(Self.block(latitude: 44.9, longitude: 29.4), within: grid)
        XCTAssertEqual(edge.north, 45.0, "clipped to the grid")
        XCTAssertEqual(edge.east, 29.5)
        let away = WindParticles.area(Self.block(latitude: 50, longitude: 10), within: grid)
        XCTAssertEqual(away.south, 40.5, "off the grid: the whole grid")
        XCTAssertEqual(away.east, 29.5)
    }

    // MARK: - Clouds and rain (owner, 2026-11-07)

    /// Light for cloud, dark for rain, none for a clear sky; the amount is
    /// the opacity.
    func testHowASkyLooks() throws {
        XCTAssertNil(CloudLook(cover: 10, rain: 0), "a clear sky draws nothing")
        let thin = try XCTUnwrap(CloudLook(cover: 20, rain: 0))
        let overcast = try XCTUnwrap(CloudLook(cover: 100, rain: 0))
        XCTAssertFalse(overcast.isRain)
        XCTAssertLessThan(thin.opacity, overcast.opacity)
        let drizzle = try XCTUnwrap(CloudLook(cover: 100, rain: 0.1))
        let downpour = try XCTUnwrap(CloudLook(cover: 100, rain: 6))
        XCTAssertTrue(drizzle.isRain, "rain is dark whatever the cover")
        XCTAssertLessThan(drizzle.opacity, downpour.opacity)
        XCTAssertEqual(downpour.opacity, 0.8, accuracy: 1e-9, "capped")
        XCTAssertEqual(CloudLook.words(cover: 80, rain: 0), "облачно 80 %")
        XCTAssertEqual(CloudLook.words(cover: 90, rain: 1.25), "дъжд 1,2 мм/ч")
        XCTAssertEqual(CloudLook.words(cover: 5, rain: 0), "ясно")
        XCTAssertEqual("облачно".capitalizedFirst, "Облачно")
    }

    /// Cover and rain mixed between grid places, like the wind.
    func testTheSkyIsMixedBetweenPlaces() throws {
        let field = WindField(hours: [Date()], latitudes: [42, 43], longitudes: [24, 25],
                              windMS: [[[0, 0], [0, 0]]], windFrom: [[[0, 0], [0, 0]]],
                              pressure: [[[1013, 1013], [1013, 1013]]],
                              cloudCover: [[[0, 100], [0, 100]]], precipitation: [[[0, 2], [0, 2]]])
        let sky = try XCTUnwrap(CloudGrid(field, hour: 0)?.at(latitude: 42.5, longitude: 24.5))
        XCTAssertEqual(sky.cover, 50, accuracy: 1e-9)
        XCTAssertEqual(sky.rain, 1, accuracy: 1e-9)
        XCTAssertNil(CloudGrid(field, hour: 1), "no such hour")
        let old = WindField(hours: [Date()], latitudes: [42, 43], longitudes: [24, 25],
                            windMS: [[[0, 0], [0, 0]]], windFrom: [[[0, 0], [0, 0]]],
                            pressure: [[[1013, 1013], [1013, 1013]]])
        XCTAssertNil(CloudGrid(old, hour: 0), "a field without clouds draws none")
    }

    /// The canvas point back to its place: the projection the other way.
    func testThePlaceUnderAPointIsTheOneDrawnThere() {
        let projection = WindProjection(region: Self.block(latitude: 43.2, longitude: 24.4),
                                        size: CGSize(width: 390, height: 700))
        for (lat, lon) in [(43.2, 24.4), (43.6, 24.1), (42.8, 24.85)] {
            let back = projection.coordinate(of: projection.point(latitude: lat, longitude: lon))
            XCTAssertEqual(back.latitude, lat, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, lon, accuracy: 1e-9)
        }
    }

    /// The seam's low brings its rain: the screenshot shows dark cloud.
    func testTheFixtureRainsAtTheLow() async throws {
        let field = try await FixtureWindFieldSource().field()
        let grid = try XCTUnwrap(CloudGrid(field, hour: 24))
        XCTAssertTrue(grid.rain.joined().contains { $0 >= CloudLook.rainFrom })
        XCTAssertTrue(grid.cover.joined().contains { $0 >= 90 })
    }
}

