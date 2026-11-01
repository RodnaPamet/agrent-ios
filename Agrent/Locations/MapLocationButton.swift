import CoreLocation
import MapKit
import SwiftUI

/// «Моето местоположение» on a farm map (#492): the one place the app asks
/// for the phone's location, and then the press that centres the map on it.
///
/// Three states, one button, so the control never disappears from under a
/// thumb that learned where it is:
/// - not asked yet: a press asks the system's "When In Use" question;
/// - allowed: a press centres the map on the dot (`centre`);
/// - refused: a press says where the setting is, with «Настройки», and
///   never asks again. iOS would not show its question a second time anyway.
///
/// Above `ParcelTargetButton` in the same corner, in the same disc.
struct MapLocationButton: View {
    /// Centres this map's camera on the position. Each map moves its own
    /// camera, so the button holds no map.
    let centre: (CLLocationCoordinate2D) -> Void

    @State private var location = DeviceLocation.shared
    @State private var explainsRefusal = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: press) {
            Image(systemName: location.access == .allowed ? "location.fill" : "location")
                .mapDisc()
        }
        .buttonStyle(.plain)
        .padding([.horizontal, .top], 16)
        .accessibilityLabel("Моето местоположение")
        .accessibilityHint(hint)
        .accessibilityInputLabels(A11y.spokenNames("Моето местоположение", "My location"))
        .alert("Местоположението е изключено", isPresented: $explainsRefusal) {
            Button("Настройки") {
                if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
            }
            Button("Отказ", role: .cancel) {}
        } message: {
            Text("За да виждате на картата къде се намирате, разрешете достъпа до местоположението за Agrent в Настройки. То се показва само на телефона и не се изпраща никъде.")
        }
    }

    private var hint: String {
        switch location.access {
        case .notAsked: "Показва на картата къде се намирате"
        case .allowed: "Центрира картата върху Вас"
        case .refused: "Достъпът до местоположението е изключен в Настройки"
        }
    }

    private func press() {
        switch location.access {
        case .notAsked:
            location.ask()
        case .allowed:
            if let position = location.position {
                centre(position.coordinate)
            } else {
                AccessibilityNotification.Announcement("Търся местоположението…").post()
            }
        case .refused:
            explainsRefusal = true
        }
    }
}

extension View {
    /// The solid disc the map's corner buttons share: 44 pt at least, grown
    /// with the text size, `Surface.bar` with its edge so it reads over any
    /// field. See `ParcelTargetButton` for why each of those.
    func mapDisc() -> some View {
        font(.title3)
            .padding(11)
            .frame(minWidth: 44, minHeight: 44)
            .background(Palette.Surface.bar, in: Circle())
            .overlay { Circle().strokeBorder(Palette.Surface.edge, lineWidth: 1) }
            .contentShape(Circle())
    }

    /// A map that shows the dot: the GPS runs while it is on screen and
    /// stops, forgetting the fix, when the last such map goes.
    func showsDeviceLocation() -> some View {
        onAppear { DeviceLocation.shared.start() }
            .onDisappear { DeviceLocation.shared.stop() }
    }
}

extension MKCoordinateRegion {
    /// Where «Моето местоположение» centres: 400 m across, which shows the
    /// field the phone is in and the edges around it.
    static func around(_ coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
    }
}
