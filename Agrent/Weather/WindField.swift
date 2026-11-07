import Foundation

/// The wind and pressure over Bulgaria, hour by hour, for the «Вятър» map
/// (owner, 2026-11-06: "the winds and the cyclones dynamics", from
/// Open-Meteo).
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
}

/// What the map draws from a field: the isobars and the centres of low and
/// high pressure. Pure, so tests pin it.
enum PressureAnalysis {
    /// One isobar: its value and its line, as coordinate pairs.
    struct Isobar: Equatable, Sendable, Identifiable {
        let hPa: Double
        let path: [(latitude: Double, longitude: Double)]
        let id: String

        static func == (a: Isobar, b: Isobar) -> Bool { a.id == b.id }
    }

    struct Centre: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable { case low, high }
        let kind: Kind
        let latitude: Double
        let longitude: Double
        let hPa: Double
        var id: String { "\(kind)\(latitude),\(longitude)" }
    }

    /// Isobars every `step` hPa, by marching squares, each joined into the
    /// longest lines its segments make.
    static func isobars(_ grid: [[Double]], latitudes: [Double], longitudes: [Double],
                        step: Double = 2) -> [Isobar] {
        let values = grid.flatMap { $0 }
        guard let low = values.min(), let high = values.max(), latitudes.count > 1, longitudes.count > 1 else {
            return []
        }
        var out: [Isobar] = []
        var level = (low / step).rounded(.up) * step
        while level <= high {
            let segments = segments(grid, at: level, latitudes: latitudes, longitudes: longitudes)
            for (i, line) in join(segments).enumerated() where line.count > 1 {
                out.append(Isobar(hPa: level, path: line, id: "\(level)-\(i)"))
            }
            level += step
        }
        return out
    }

    private typealias Coordinate = (latitude: Double, longitude: Double)

    /// Marching squares: in each cell, where the level crosses its edges.
    private static func segments(_ grid: [[Double]], at level: Double,
                                 latitudes: [Double], longitudes: [Double]) -> [(Coordinate, Coordinate)] {
        var out: [(Coordinate, Coordinate)] = []
        func cross(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> Coordinate? {
            let a = grid[r0][c0], b = grid[r1][c1]
            guard (a < level) != (b < level) else { return nil }
            let t = (level - a) / (b - a)
            return (latitudes[r0] + (latitudes[r1] - latitudes[r0]) * t,
                    longitudes[c0] + (longitudes[c1] - longitudes[c0]) * t)
        }
        for r in 0..<(latitudes.count - 1) {
            for c in 0..<(longitudes.count - 1) {
                let crossings = [cross(r, c, r, c + 1), cross(r, c + 1, r + 1, c + 1),
                                 cross(r + 1, c + 1, r + 1, c), cross(r + 1, c, r, c)].compactMap { $0 }
                if crossings.count == 2 {
                    out.append((crossings[0], crossings[1]))
                } else if crossings.count == 4 {
                    // A saddle: paired in order round the cell.
                    out.append((crossings[0], crossings[1]))
                    out.append((crossings[2], crossings[3]))
                }
            }
        }
        return out
    }

    /// Segments sharing an end, joined into lines.
    private static func join(_ segments: [(Coordinate, Coordinate)]) -> [[Coordinate]] {
        func key(_ p: Coordinate) -> String {
            "\((p.latitude * 1e5).rounded()),\((p.longitude * 1e5).rounded())"
        }
        var remaining = segments
        var lines: [[Coordinate]] = []
        while let first = remaining.popLast() {
            var line = [first.0, first.1]
            var grew = true
            while grew {
                grew = false
                for (i, segment) in remaining.enumerated() {
                    let head = key(line[0]), tail = key(line[line.count - 1])
                    if key(segment.0) == tail { line.append(segment.1) }
                    else if key(segment.1) == tail { line.append(segment.0) }
                    else if key(segment.1) == head { line.insert(segment.0, at: 0) }
                    else if key(segment.0) == head { line.insert(segment.1, at: 0) }
                    else { continue }
                    remaining.remove(at: i)
                    grew = true
                    break
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// Centres of low and high pressure: interior points lower (or higher)
    /// than all eight neighbours, by at least `depth` hPa below (above) their
    /// mean, so a flat field marks nothing.
    static func centres(_ grid: [[Double]], latitudes: [Double], longitudes: [Double],
                        depth: Double = 0.5) -> [Centre] {
        guard latitudes.count > 2, longitudes.count > 2 else { return [] }
        var out: [Centre] = []
        for r in 1..<(latitudes.count - 1) {
            for c in 1..<(longitudes.count - 1) {
                let v = grid[r][c]
                var neighbours: [Double] = []
                for dr in -1...1 { for dc in -1...1 where !(dr == 0 && dc == 0) { neighbours.append(grid[r + dr][c + dc]) } }
                let mean = neighbours.reduce(0, +) / Double(neighbours.count)
                if neighbours.allSatisfy({ v < $0 }), mean - v >= depth {
                    out.append(Centre(kind: .low, latitude: latitudes[r], longitude: longitudes[c], hPa: v))
                } else if neighbours.allSatisfy({ v > $0 }), v - mean >= depth {
                    out.append(Centre(kind: .high, latitude: latitudes[r], longitude: longitudes[c], hPa: v))
                }
            }
        }
        return out
    }
}
