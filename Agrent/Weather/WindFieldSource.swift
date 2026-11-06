import Foundation

/// Where the «Вятър» map's field comes from: Open-Meteo, on the owner's
/// word (2026-11-06). A protocol so A11yShots draws it from a fixture and no
/// test calls Open-Meteo.
protocol WindFieldSource: Sendable {
    func field() async throws -> WindField
}

enum WindFieldSources {
    static var current: any WindFieldSource {
        #if DEBUG
        if UITestSeam.isActive { return FixtureWindFieldSource() }
        #endif
        return OpenMeteoWindSource()
    }
}

/// Open-Meteo's forecast API: one request for the whole grid (170 places),
/// 48 hours of 10 m wind and sea-level pressure, in m/s and hPa.
///
/// ── The FREE tier, knowingly ──
///
/// Open-Meteo's free tier is for non-commercial use, and Agrent has
/// subscriptions. The owner was told and chose it anyway (2026-11-06). The
/// paid tier is the same request on `customer-api.open-meteo.com` with an
/// `apikey`, which is `OpenMeteoAPI.url(apiKey:)`'s switch; a key must
/// never be in this public repo, so a paid one goes through the server.
///
/// One opening is 170 of the free tier's calls (one per place); the free
/// limit is 10 000 a day per address, so the field is kept for half an
/// hour (`OpenMeteoWindSource.cache`).
struct OpenMeteoWindSource: WindFieldSource {
    func field() async throws -> WindField {
        if let cached = await OpenMeteoCache.shared.fresh() { return cached }
        var request = URLRequest(url: OpenMeteoAPI.url(), cachePolicy: .reloadIgnoringLocalCacheData)
        ClientHeader.stamp(&request)
        request.httpShouldHandleCookies = false
        let (data, response) = try await NoURLCache.thirdPartySession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let field = try OpenMeteoAPI.decode(data)
        await OpenMeteoCache.shared.keep(field)
        return field
    }
}

/// Half an hour of the last field, in memory: the model runs every few
/// hours, and a farmer flipping between blocks should not spend the free
/// tier's calls on the same grid.
actor OpenMeteoCache {
    static let shared = OpenMeteoCache()
    private var kept: (field: WindField, at: Date)?

    func fresh(now: Date = Date()) -> WindField? {
        guard let kept, now.timeIntervalSince(kept.at) < 30 * 60 else { return nil }
        return kept.field
    }

    func keep(_ field: WindField, now: Date = Date()) { kept = (field, now) }

    func clear() { kept = nil }
}

enum OpenMeteoAPI {
    /// The request: every grid place, comma-separated, as the API takes many
    /// locations at once. `apiKey` moves it to the paid endpoint.
    static func url(apiKey: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiKey == nil ? "api.open-meteo.com" : "customer-api.open-meteo.com"
        components.path = "/v1/forecast"
        var latitudes: [String] = [], longitudes: [String] = []
        for lat in WindGrid.latitudes {
            for lon in WindGrid.longitudes {
                latitudes.append(String(lat))
                longitudes.append(String(lon))
            }
        }
        var items = [
            URLQueryItem(name: "latitude", value: latitudes.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: longitudes.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,pressure_msl"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "forecast_hours", value: String(WindGrid.hours)),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        if let apiKey { items.append(URLQueryItem(name: "apikey", value: apiKey)) }
        components.queryItems = items
        return components.url!
    }

    private struct Place: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let wind_speed_10m: [Double?]
            let wind_direction_10m: [Double?]
            let pressure_msl: [Double?]
        }
        let hourly: Hourly
    }

    /// Open-Meteo answers an ARRAY for many places, in the order asked, so
    /// place `r * columns + c` is grid row `r`, column `c`. A missing value
    /// takes its neighbour's in time, so one gap does not drop the field.
    static func decode(_ data: Data) throws -> WindField {
        let places = try JSONDecoder().decode([Place].self, from: data)
        let rows = WindGrid.latitudes.count, columns = WindGrid.longitudes.count
        guard places.count == rows * columns, let first = places.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "grid size"))
        }
        let hours = first.hourly.time.compactMap(parseHour)
        let count = hours.count
        func cube(_ pick: (Place.Hourly) -> [Double?]) -> [[[Double]]] {
            (0..<count).map { h in
                (0..<rows).map { r in
                    (0..<columns).map { c in
                        let series = pick(places[r * columns + c].hourly)
                        return series.indices.contains(h) ? (series[h] ?? series[..<h].compactMap { $0 }.last ?? 0) : 0
                    }
                }
            }
        }
        return WindField(hours: hours, latitudes: WindGrid.latitudes, longitudes: WindGrid.longitudes,
                         windMS: cube(\.wind_speed_10m), windFrom: cube(\.wind_direction_10m),
                         pressure: cube(\.pressure_msl))
    }

    /// «2026-11-06T18:00», GMT as asked.
    static func parseHour(_ text: String) -> Date? {
        BgDate.parseInstant(text + ":00Z")
    }
}

#if DEBUG
/// A synthetic low crossing Bulgaria from the west over 48 hours, for
/// A11yShots: pressure 1002 at its centre, wind turning round it. Invented.
struct FixtureWindFieldSource: WindFieldSource {
    func field() async throws -> WindField {
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let lats = WindGrid.latitudes, lons = WindGrid.longitudes
        var wind: [[[Double]]] = [], from: [[[Double]]] = [], pressure: [[[Double]]] = []
        for h in 0..<WindGrid.hours {
            let centreLon = 22.0 + Double(h) * 0.13
            let centreLat = 42.8
            var w: [[Double]] = [], f: [[Double]] = [], p: [[Double]] = []
            for lat in lats {
                var wr: [Double] = [], fr: [Double] = [], pr: [Double] = []
                for lon in lons {
                    let dy = lat - centreLat, dx = lon - centreLon
                    let distance = (dx * dx + dy * dy).squareRoot()
                    pr.append(1002 + min(distance, 6) * 2.4)
                    wr.append(max(2, 12 - abs(distance - 1.5) * 3))
                    // Anticlockwise round a northern low: the wind comes from
                    // 90° to the right of the line to the centre.
                    let bearing = atan2(dx, dy) * 180 / .pi
                    fr.append((bearing + 270).truncatingRemainder(dividingBy: 360))
                }
                w.append(wr); f.append(fr); p.append(pr)
            }
            wind.append(w); from.append(f); pressure.append(p)
        }
        return WindField(hours: (0..<WindGrid.hours).map { start.addingTimeInterval(Double($0) * 3600) },
                         latitudes: lats, longitudes: lons, windMS: wind, windFrom: from, pressure: pressure)
    }
}
#endif
