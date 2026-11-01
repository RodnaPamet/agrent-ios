import CoreLocation
import Observation

/// Where the phone is, for the farm's maps (#492, owner 2026-11-01): a «you
/// are here» dot so a mechanisator sees which field, and where in it, they
/// stand, and «Нов запис» ticking the parcel they stand in.
///
/// ── The position never leaves the phone ──
///
/// The owner's choice, and why App Privacy and `PrivacyInfo.xcprivacy` declare
/// no location: Apple counts data as collected only once it is sent off the
/// device. So the position lives in memory here and nowhere else. No request,
/// cache, log or stored setting sees it, and the only thing derived from it
/// that can travel is a parcel the person then saves themselves.
/// `PrivacyManifestTests.testTheDeviceLocationNeverLeavesThePhone` keeps the
/// readers to the map files.
///
/// ── Asked from a map, never at launch ──
///
/// "When In Use" only, and only when the person presses the location button
/// on a map (`ask()`). Until then, and after a refusal, every map works as it
/// did before: no dot, no prompt, no nagging. Updates run only while a map
/// that shows the dot is on screen (`start()`/`stop()`, counted), so the GPS
/// is off the rest of the time.
@MainActor @Observable
final class DeviceLocation: NSObject, CLLocationManagerDelegate {
    static let shared = DeviceLocation()

    enum Access: Equatable {
        /// Not asked yet: the button asks.
        case notAsked
        case allowed
        /// Refused, or restricted by the phone's settings: the button says
        /// where to turn it on.
        case refused
    }

    private(set) var access: Access = .notAsked
    /// The latest fix, or nil before the first one or once the maps closed.
    private(set) var position: CLLocation?

    /// A fix this far off or worse can't say which side of a boundary the
    /// phone is on, so it puts nobody in a parcel. Field GPS is 5–10 m.
    nonisolated static let usableAccuracy: CLLocationAccuracy = 30

    @ObservationIgnored private let manager = CLLocationManager()
    /// The maps on screen that show the dot.
    @ObservationIgnored private var viewers = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // A walking pace across a field; a fix per metre is noise.
        manager.distanceFilter = 3
        access = Self.access(manager.authorizationStatus)
    }

    /// The location button: the system's question the first time, nothing
    /// after (the button then centres, or says where the setting is).
    func ask() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// A map showing the dot appeared.
    func start() {
        viewers += 1
        if access == .allowed { manager.startUpdatingLocation() }
    }

    /// It went away. The last map out stops the GPS and forgets the fix.
    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        manager.stopUpdatingLocation()
        position = nil
    }

    /// The position when it is good enough to say which parcel it is in.
    var usablePosition: CLLocation? {
        guard let position, position.horizontalAccuracy >= 0,
              position.horizontalAccuracy <= Self.usableAccuracy else { return nil }
        return position
    }

    nonisolated static func access(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .denied, .restricted: .refused
        case .notDetermined: .notAsked
        @unknown default: .refused
        }
    }

    // MARK: - CLLocationManagerDelegate

    // The manager is made on the main thread, so its callbacks arrive there.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            access = Self.access(status)
            if access == .allowed, viewers > 0 {
                self.manager.startUpdatingLocation()
            } else if access != .allowed {
                self.manager.stopUpdatingLocation()
                position = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated {
            guard viewers > 0 else { return }
            position = latest
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // `locationUnknown` is transient and the manager keeps trying; the
        // dot simply waits. Nothing is logged: a log line is somewhere the
        // position must never go, and the error carries nothing to act on.
    }
}
