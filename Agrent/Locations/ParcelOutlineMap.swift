import MapKit
import SwiftUI

/// The parcel on the map, at the top of its history (owner, 2026-11-06:
/// "add box with the parcel on the map when the parcel's history page is
/// open"): its outline over the imagery, framed to fit, and the phone's
/// dot with «Намирате се в …» while it stands inside.
///
/// Still, like the task's map (`TaskParcelMap`): in a scrolling page a map
/// that took the drag would steal the scroll, and the camera already frames
/// the one parcel this page is about. Блокове is where a farm is explored.
struct ParcelOutlineMap: View {
    let parcel: Parcel

    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 180
    @State private var location = DeviceLocation.shared

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(fitting: [parcel]) ?? .bulgaria), interactionModes: []) {
            ForEach(Array((parcel.geometry?.mapPolygons ?? []).enumerated()), id: \.offset) { _, polygon in
                MapPolygon(polygon)
                    .foregroundStyle(Palette.Map.TaskParcels.marked.opacity(0.28))
                    .stroke(Palette.Map.TaskParcels.marked, lineWidth: 2)
            }
            if location.access == .allowed { UserAnnotation() }
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: min(scaledHeight, 300))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(parcel.name) на картата")
        .accessibilityAddTraits(.isImage)
        .overlay(alignment: .top) { StandingInLabel(parcels: [parcel]) }
        .showsDeviceLocation()
    }
}
