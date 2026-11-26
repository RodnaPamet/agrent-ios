import CoreLocation
import Foundation

/// WHERE Табло's weather is for (#671). Owner, 2026-11-17: where the phone is,
/// rounded to about 5 km before it goes anywhere — enough for weather, not a
/// precise location — and declared to Apple as Coarse Location. Without
/// permission, the centre of the farm's blocks.
///
/// ── The one file that lets the position out ──
///
/// Every other reader of the device's location only draws it on a map
/// (`PrivacyManifestTests`). This one hands a coordinate to the weather
/// sources, so the rounding happens HERE, before anything else sees the
/// value: nothing downstream can send what it never received.
enum WeatherPlace {
    struct Point: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        /// From the phone (rounded) rather than from the farm's blocks.
        let isPhone: Bool
    }

    /// 0.05° — about 5,5 km north–south and 4 km east–west in Bulgaria.
    static let grid = 0.05

    /// Rounded to the grid AND to at most two decimals as written. Apple's
    /// line between Coarse and Precise Location is "three or more decimal
    /// places", and `(v / 0.05).rounded() * 0.05` can come out as
    /// 43.150000000000006 — coarse in fact, fifteen decimals in the request.
    /// Whole hundredths divided by 100 print as written («43.15»).
    static func rounded(_ value: Double) -> Double {
        let steps = Int((value / grid).rounded())
        return Double(steps * 5) / 100
    }

    /// The phone's rounded position, else the centre of the blocks' outlines.
    @MainActor
    static func current(blocks: [Location]) -> Point? {
        // Any fix better than the 5 km it is rounded to will do: the map's
        // `usablePosition` asks for metres, which a weather card does not need.
        if let position = DeviceLocation.shared.position,
           position.horizontalAccuracy >= 0, position.horizontalAccuracy <= 3_000 {
            return Point(latitude: rounded(position.coordinate.latitude),
                         longitude: rounded(position.coordinate.longitude), isPhone: true)
        }
        return farmCentre(blocks)
    }

    /// The mean of the blocks' bounding-box centres. The farm's own map
    /// coordinate, as the weather sheet already sends for one block.
    static func farmCentre(_ blocks: [Location]) -> Point? {
        let boxes = blocks.compactMap(\.boundsJson)
        guard !boxes.isEmpty else { return nil }
        let lat = boxes.map { ($0.minLat + $0.maxLat) / 2 }.reduce(0, +) / Double(boxes.count)
        let lon = boxes.map { ($0.minLon + $0.maxLon) / 2 }.reduce(0, +) / Double(boxes.count)
        return Point(latitude: lat, longitude: lon, isPhone: false)
    }

    /// Asks once (the system remembers the answer) and starts the updates the
    /// position comes from; Табло stops them when it goes.
    @MainActor
    static func startLocating() {
        #if DEBUG
        // Synthetic data never asks: the system's prompt would cover the
        // screen being photographed, and the fixture farm has blocks.
        if UITestSeam.isActive { return }
        #endif
        DeviceLocation.shared.ask()
        DeviceLocation.shared.start()
    }

    @MainActor
    static func stopLocating() { DeviceLocation.shared.stop() }
}
