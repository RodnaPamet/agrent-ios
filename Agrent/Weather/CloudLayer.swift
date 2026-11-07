import MapKit
import SwiftUI

/// Clouds and rain under the wind (owner, 2026-11-07: "Can you include
/// clouds as well? Like dark clouds for rain and light for cloudy
/// weather"), from the same Open-Meteo field: cloud cover in % and the
/// hour's rain in mm.
///
/// ── How ──
///
/// The view is sampled on a coarse screen grid; each sample is turned back
/// into a place (`WindProjection.coordinate`), the cover and rain there are
/// mixed from the four grid places round it, and a translucent square is
/// filled in the cloud's colour. A blur then melts the squares into soft
/// cloud. Light grey where it is cloudy, dark slate where it rains; the
/// amount is the opacity (`CloudLook`).
struct CloudLayer: View {
    let field: WindField
    let hour: Int
    /// As `WindFlowLayer`'s: read every frame, so the clouds stay on the land
    /// while the map pans without the map re-rendering.
    let region: () -> MKCoordinateRegion
    /// Over a satellite photograph: the cloud near-white rather than grey,
    /// as the photograph is dark (the block's map, owner 2026-11-07).
    var onImagery = false

    /// Points between samples. Coarse on purpose: the grid is half a degree
    /// and the blur does the rest.
    static let sample: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                guard let grid = CloudGrid(field, hour: hour) else { return }
                let projection = WindProjection(region: region(), size: size)
                context.addFilter(.blur(radius: Self.sample * 1.2))
                var y: CGFloat = 0
                while y < size.height + Self.sample {
                    var x: CGFloat = 0
                    while x < size.width + Self.sample {
                        let place = projection.coordinate(of: CGPoint(x: x, y: y))
                        if let sky = grid.at(latitude: place.latitude, longitude: place.longitude),
                           let look = CloudLook(cover: sky.cover, rain: sky.rain) {
                            let square = CGRect(x: x - Self.sample / 2, y: y - Self.sample / 2,
                                                width: Self.sample + 1, height: Self.sample + 1)
                            let color = look.isRain ? Palette.Weather.rain
                                : onImagery ? Palette.Weather.cloudOnImagery : Palette.Weather.cloud
                            context.fill(Path(square), with: .color(color.opacity(look.opacity)))
                        }
                        x += Self.sample
                    }
                    y += Self.sample
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One hour's cloud cover and rain, mixed between grid places.
struct CloudGrid: Equatable, Sendable {
    let latitudes: [Double]
    let longitudes: [Double]
    let cover: [[Double]]
    let rain: [[Double]]

    /// Nil when the field has no clouds for `hour` (asked before clouds
    /// were, or a gap).
    init?(_ field: WindField, hour: Int) {
        guard field.cloudCover.indices.contains(hour), field.precipitation.indices.contains(hour) else {
            return nil
        }
        latitudes = field.latitudes
        longitudes = field.longitudes
        cover = field.cloudCover[hour]
        rain = field.precipitation[hour]
    }

    func at(latitude: Double, longitude: Double) -> (cover: Double, rain: Double)? {
        guard let r = Self.cell(latitude, in: latitudes), let c = Self.cell(longitude, in: longitudes),
              cover.indices.contains(r + 1), rain.indices.contains(r + 1) else { return nil }
        let ty = (latitude - latitudes[r]) / (latitudes[r + 1] - latitudes[r])
        let tx = (longitude - longitudes[c]) / (longitudes[c + 1] - longitudes[c])
        func mix(_ g: [[Double]]) -> Double {
            let south = g[r][c] * (1 - tx) + g[r][c + 1] * tx
            let north = g[r + 1][c] * (1 - tx) + g[r + 1][c + 1] * tx
            return south * (1 - ty) + north * ty
        }
        return (mix(cover), mix(rain))
    }

    private static func cell(_ value: Double, in axis: [Double]) -> Int? {
        guard axis.count > 1, let first = axis.first, let last = axis.last, value >= first, value <= last else {
            return nil
        }
        let step = (last - first) / Double(axis.count - 1)
        return min(Int((value - first) / step), axis.count - 2)
    }
}

/// How a sky looks: nothing below a fifth of cover, light cloud up to
/// overcast, dark from a tenth of a millimetre of rain in the hour, darker
/// as it rains harder. Pure, so tests pin it.
struct CloudLook: Equatable, Sendable {
    let isRain: Bool
    let opacity: Double

    /// A trace this small is drizzle at most; below it, the cover decides.
    static let rainFrom = 0.1

    init?(cover: Double, rain: Double) {
        if rain >= Self.rainFrom {
            isRain = true
            // 0.1 mm → 0.4, 4 mm and more → 0.8.
            opacity = 0.4 + min(rain, 4) / 4 * 0.4
        } else if cover >= 20 {
            isRain = false
            // A fifth of the sky → 0.18, overcast → 0.6.
            opacity = 0.18 + (min(cover, 100) - 20) / 80 * 0.42
        } else {
            return nil
        }
    }

    /// «облачно 80 %», «дъжд 1,2 мм/ч», for the block's line and VoiceOver.
    static func words(cover: Double, rain: Double) -> String {
        if rain >= rainFrom {
            return "дъжд \(WeatherWords.number(rain, places: 1)) мм/ч"
        }
        return cover >= 20 ? "облачно \(WeatherWords.number(cover, places: 0)) %" : "ясно"
    }
}

extension WindProjection {
    /// The place under a canvas point: `point(latitude:longitude:)` the other
    /// way round, through the inverse of the same Mercator.
    func coordinate(of point: CGPoint) -> (latitude: Double, longitude: Double) {
        let west = region.center.longitude - region.span.longitudeDelta / 2
        func mercator(_ latitude: Double) -> Double { log(tan(.pi / 4 + latitude * .pi / 360)) }
        let north = mercator(region.center.latitude + region.span.latitudeDelta / 2)
        let south = mercator(region.center.latitude - region.span.latitudeDelta / 2)
        let longitude = west + Double(point.x / max(size.width, 1)) * region.span.longitudeDelta
        let m = north - Double(point.y / max(size.height, 1)) * (north - south)
        let latitude = (2 * atan(exp(m)) - .pi / 2) * 180 / .pi
        return (latitude, longitude)
    }
}

extension String {
    /// «Облачно 80 %»: the first letter only, as a line starts.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

