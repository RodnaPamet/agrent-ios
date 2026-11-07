import Foundation
import MapKit

/// The wind, pressure, clouds and rain over Bulgaria, hour by hour, from
/// Open-Meteo, drawn on a block's own map (owner, 2026-11-06 and -07). The
/// full-screen «Вятър» map that first drew it, with its isobars and
/// pressure centres, was removed on the owner's word (2026-11-07: "this is
/// better, remove the wind button from the top"); it is in git history.
///
/// A regular grid, rows south to north and columns west to east, the same
/// for every farm: nothing about the farm is in the request.
struct WindField: Equatable, Sendable {
    /// The forecast hours, oldest first.
    let hours: [Date]
    /// Latitudes, south to north.
    let latitudes: [Double]
    /// Longitudes, west to east.
    let longitudes: [Double]
    /// `[hour][row][column]`, m/s.
    let windMS: [[[Double]]]
    /// `[hour][row][column]`, degrees the wind comes FROM.
    let windFrom: [[[Double]]]
    /// `[hour][row][column]`, hPa at sea level.
    let pressure: [[[Double]]]
    /// `[hour][row][column]`, % of the sky (owner, 2026-11-07: clouds).
    var cloudCover: [[[Double]]] = []
    /// `[hour][row][column]`, mm of rain (or melted snow) in the hour.
    var precipitation: [[[Double]]] = []

    struct Point: Equatable, Sendable, Identifiable {
        let latitude: Double
        let longitude: Double
        let windMS: Double
        let windFrom: Double
        var id: String { "\(latitude),\(longitude)" }
    }

    /// The wind at every grid point at `hour`.
    func points(at hour: Int) -> [Point] {
        guard windMS.indices.contains(hour) else { return [] }
        var out: [Point] = []
        for (r, lat) in latitudes.enumerated() {
            for (c, lon) in longitudes.enumerated() {
                out.append(Point(latitude: lat, longitude: lon,
                                 windMS: windMS[hour][r][c], windFrom: windFrom[hour][r][c]))
            }
        }
        return out
    }
}

/// The grid asked of Open-Meteo: Bulgaria and a margin, every half degree
/// (about 50 km). Coarse enough to be one request of 170 locations, fine
/// enough for the isobars and the lows over the Balkans to be where they are.
enum WindGrid {
    static let latitudes: [Double] = stride(from: 40.5, through: 45.0, by: 0.5).map { $0 }
    static let longitudes: [Double] = stride(from: 21.5, through: 29.5, by: 0.5).map { $0 }
    static let hours = 48

    /// Bulgaria with its margin, as the grid covers it: the reference span
    /// the streaks' on-screen speed is scaled from.
    static let bulgaria = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.75, longitude: 25.5),
        span: MKCoordinateSpan(latitudeDelta: 4.8, longitudeDelta: 8.4))
}
