import MapKit
import SwiftUI

/// The wind as moving streaks (owner, 2026-11-06: "It will be better
/// animated, right, not with arrows only"): particles carried by the wind
/// across the grid, each leaving a short fading trail, faster where the
/// wind is stronger, coloured by the same bands as the arrows. Earth.nullschool's
/// and Windy's way of drawing a wind field.
///
/// ── How ──
///
/// The grid's wind (speed and where it comes FROM) becomes east and north
/// components, interpolated between the four grid places round a particle.
/// Each frame moves every particle by that wind, ages it, and sends it back
/// to a random place when it is old or leaves the grid. Drawn in a `Canvas`
/// over the map, projected with the map's own visible region (Mercator), so
/// it stays on the land it describes while the map pans and zooms.
///
/// Pure where it can be: `WindVectors` and `WindProjection` are tested.

/// The grid's wind at one hour as east (u) and north (v) components, m/s.
struct WindVectors: Equatable, Sendable {
    let latitudes: [Double]
    let longitudes: [Double]
    let u: [[Double]]
    let v: [[Double]]

    /// From a field's hour. The wind comes FROM `windFrom`, so it blows
    /// towards the opposite bearing: from the west (270°) is u > 0.
    init(_ field: WindField, hour: Int) {
        latitudes = field.latitudes
        longitudes = field.longitudes
        guard field.windMS.indices.contains(hour) else {
            u = []; v = []
            return
        }
        var us: [[Double]] = [], vs: [[Double]] = []
        for r in field.latitudes.indices {
            var ur: [Double] = [], vr: [Double] = []
            for c in field.longitudes.indices {
                let speed = field.windMS[hour][r][c]
                let from = field.windFrom[hour][r][c] * .pi / 180
                ur.append(-speed * sin(from))
                vr.append(-speed * cos(from))
            }
            us.append(ur); vs.append(vr)
        }
        u = us; v = vs
    }

    /// The wind at a place inside the grid, bilinear between its four
    /// corners; nil outside.
    func at(latitude: Double, longitude: Double) -> (u: Double, v: Double)? {
        guard !u.isEmpty, let r = Self.cell(latitude, in: latitudes), let c = Self.cell(longitude, in: longitudes) else {
            return nil
        }
        let ty = (latitude - latitudes[r]) / (latitudes[r + 1] - latitudes[r])
        let tx = (longitude - longitudes[c]) / (longitudes[c + 1] - longitudes[c])
        func mix(_ g: [[Double]]) -> Double {
            let south = g[r][c] * (1 - tx) + g[r][c + 1] * tx
            let north = g[r + 1][c] * (1 - tx) + g[r + 1][c + 1] * tx
            return south * (1 - ty) + north * ty
        }
        return (mix(u), mix(v))
    }

    /// The wind's speed (m/s) and where it comes FROM (degrees) at a place,
    /// for saying it in words: the opposite of where (u, v) blows to.
    func speedAndFrom(latitude: Double, longitude: Double) -> (speed: Double, from: Double)? {
        guard let w = at(latitude: latitude, longitude: longitude) else { return nil }
        let towards = atan2(w.u, w.v) * 180 / .pi
        return ((w.u * w.u + w.v * w.v).squareRoot(), (towards + 180 + 360).truncatingRemainder(dividingBy: 360))
    }

    /// The hour of `field` to show now: the one under way, or the first.
    static func hourNow(_ field: WindField, now: Date = Date()) -> Int {
        field.hours.lastIndex { $0 <= now } ?? 0
    }

    /// The lower index of the cell holding `value`, nil outside.
    private static func cell(_ value: Double, in axis: [Double]) -> Int? {
        guard axis.count > 1, let first = axis.first, let last = axis.last, value >= first, value <= last else {
            return nil
        }
        let step = (last - first) / Double(axis.count - 1)
        return min(Int((value - first) / step), axis.count - 2)
    }
}

/// The map's visible region to the canvas's points, in Web Mercator, as
/// MapKit draws it.
struct WindProjection: Equatable, Sendable {
    let region: MKCoordinateRegion
    let size: CGSize

    static func == (a: WindProjection, b: WindProjection) -> Bool {
        a.size == b.size && a.region.center.latitude == b.region.center.latitude
            && a.region.center.longitude == b.region.center.longitude
            && a.region.span.latitudeDelta == b.region.span.latitudeDelta
            && a.region.span.longitudeDelta == b.region.span.longitudeDelta
    }

    private static func mercator(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude * .pi / 360))
    }

    func point(latitude: Double, longitude: Double) -> CGPoint {
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let north = Self.mercator(region.center.latitude + region.span.latitudeDelta / 2)
        let south = Self.mercator(region.center.latitude - region.span.latitudeDelta / 2)
        let x = (longitude - west) / region.span.longitudeDelta * size.width
        let y = (north - Self.mercator(latitude)) / (north - south) * size.height
        return CGPoint(x: x, y: y)
    }
}

/// The particles. A reference type held by the view and stepped as the
/// canvas draws: the frame IS the clock, and nothing else reads them.
@MainActor
final class WindParticles {
    struct Particle {
        var latitude: Double
        var longitude: Double
        var age: Double
        var life: Double
        var trail: [(latitude: Double, longitude: Double)]
        /// Time since the trail last took a point.
        var sinceSample: Double = 0
    }

    /// All in view now (`area`), so fewer than the country once needed:
    /// 1100 in a degree read as a wall (measured, 2026-11-07).
    static let count = 500
    /// How long a streak is: a point every `sampleEvery` seconds, so the
    /// length is the same at any frame rate (the first version counted
    /// frames, and on a slow frame rate the streaks were dots).
    static let trailLength = 9
    static let sampleEvery = 0.05
    /// Degrees of latitude per second for 1 m/s: a 10 m/s wind moves half a
    /// degree (one grid cell, ~25 points on the whole-country view) a
    /// second, so a streak is long enough to show its direction.
    static let speedScale = 0.05

    private(set) var particles: [Particle] = []
    private var lastTick: Date?
    typealias Box = (south: Double, north: Double, west: Double, east: Double)
    /// The grid's extent: no wind is known outside it.
    private var grid: Box = (0, 0, 0, 0)
    /// Where particles are born: what the map shows, within the grid. So a
    /// block zoomed into keeps all its streaks rather than the few of the
    /// whole country's that happen to fall in view (owner's screenshot,
    /// 2026-11-07).
    private var area: Box = (0, 0, 0, 0)

    func reset(latitudes: [Double], longitudes: [Double]) {
        guard let south = latitudes.first, let north = latitudes.last,
              let west = longitudes.first, let east = longitudes.last else { return }
        grid = (south, north, west, east)
        area = grid
        particles = (0..<Self.count).map { _ in spawn(age: Double.random(in: 0...4)) }
        lastTick = nil
    }

    /// The visible region, within the grid; the whole grid when the two
    /// do not meet.
    nonisolated static func area(_ region: MKCoordinateRegion, within grid: Box) -> Box {
        let south = max(grid.south, region.center.latitude - region.span.latitudeDelta / 2)
        let north = min(grid.north, region.center.latitude + region.span.latitudeDelta / 2)
        let west = max(grid.west, region.center.longitude - region.span.longitudeDelta / 2)
        let east = min(grid.east, region.center.longitude + region.span.longitudeDelta / 2)
        return south < north && west < east ? (south, north, west, east) : grid
    }

    private func spawn(age: Double = 0) -> Particle {
        let lat = Double.random(in: area.south...area.north)
        let lon = Double.random(in: area.west...area.east)
        return Particle(latitude: lat, longitude: lon, age: age, life: Double.random(in: 3...7),
                        trail: [(lat, lon), (lat, lon)])
    }

    private func outside(_ p: Particle) -> Bool {
        p.latitude < area.south || p.latitude > area.north || p.longitude < area.west || p.longitude > area.east
    }

    /// One frame: move every particle by the wind where it is, at the same
    /// speed ON SCREEN whatever the zoom (the scale is the whole country's,
    /// adjusted by how much of it is in view).
    func step(_ wind: WindVectors, now: Date, region: MKCoordinateRegion) {
        let dt = min(lastTick.map { now.timeIntervalSince($0) } ?? 0, 0.1)
        lastTick = now
        guard dt > 0 else { return }
        area = Self.area(region, within: grid)
        let scale = Self.speedScale * region.span.latitudeDelta / WindMapView.bulgaria.span.latitudeDelta
        for i in particles.indices {
            var p = particles[i]
            p.age += dt
            guard p.age < p.life, !outside(p), let w = wind.at(latitude: p.latitude, longitude: p.longitude) else {
                particles[i] = spawn()
                continue
            }
            p.latitude += w.v * scale * dt
            p.longitude += w.u * scale * dt / max(cos(p.latitude * .pi / 180), 0.2)
            p.sinceSample += dt
            if p.sinceSample >= Self.sampleEvery {
                p.sinceSample = 0
                p.trail.append((p.latitude, p.longitude))
                if p.trail.count > Self.trailLength { p.trail.removeFirst(p.trail.count - Self.trailLength) }
            } else if !p.trail.isEmpty {
                // The head follows the particle between samples.
                p.trail[p.trail.count - 1] = (p.latitude, p.longitude)
            }
            particles[i] = p
        }
    }
}

/// The streaks, drawn over the map. Not interactive and not read by
/// VoiceOver: the map's summary says the wind in words.
struct WindFlowLayer: View {
    let wind: WindVectors
    /// The map's region AS IT IS NOW, read every frame: the block map hands
    /// in a box its UIKit map writes to while it pans, so the streaks stay
    /// on the land without the map re-rendering 60 times a second.
    let region: () -> MKCoordinateRegion
    let particles: WindParticles
    /// A dark edge under each streak, for a satellite photograph, which can
    /// be any colour (`Palette.Map.labelHalo`, the map labels' own).
    var halo = false

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let region = region()
                particles.step(wind, now: timeline.date, region: region)
                let projection = WindProjection(region: region, size: size)
                // Two paths per band: the older half of each trail faint, the
                // newer half strong, so a streak fades behind its head. Eight
                // strokes a frame rather than one per particle.
                let bands = WindMapWords.bands.count
                var tails = Array(repeating: Path(), count: bands)
                var heads = Array(repeating: Path(), count: bands)
                for particle in particles.particles where particle.trail.count > 2 {
                    guard let w = wind.at(latitude: particle.latitude, longitude: particle.longitude) else { continue }
                    let speed = (w.u * w.u + w.v * w.v).squareRoot()
                    let band = WindMapWords.bands.firstIndex { speed < $0.upTo } ?? bands - 1
                    let points = particle.trail.map { projection.point(latitude: $0.latitude, longitude: $0.longitude) }
                    let middle = points.count / 2
                    tails[band].addLines(Array(points[...middle]))
                    heads[band].addLines(Array(points[middle...]))
                }
                let style = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                if halo {
                    let edge = StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round)
                    for band in 0..<bands {
                        context.stroke(heads[band], with: .color(Palette.Map.labelHalo.opacity(0.55)), style: edge)
                    }
                }
                for band in 0..<bands {
                    let color = WindMapWords.bands[band].color
                    context.stroke(tails[band], with: .color(color.opacity(0.3)), style: style)
                    context.stroke(heads[band], with: .color(color.opacity(0.95)), style: style)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The map's region, written by a UIKit map as it moves and read by a layer
/// as it draws. A reference type and not observed on purpose: a SwiftUI
/// state written every frame of a pan would re-render the map it came from.
@MainActor
final class MapRegionBox {
    var region: MKCoordinateRegion
    init(_ region: MKCoordinateRegion) { self.region = region }
}

