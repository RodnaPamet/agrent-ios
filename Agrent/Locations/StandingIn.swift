import CoreLocation
import MapKit
import SwiftUI

/// Which of a map's parcels the phone stands in (#492), for the «Намирате се
/// в …» label on every farm map and for «Нов запис» ticking that parcel.
///
/// The map's own hit test, applied to the position: inside the outer ring and
/// outside every hole (`TreatmentPlace.contains`), the smallest parcel first
/// where outlines overlap, as a tap resolves it. And only on a fix good
/// enough to tell the two sides of a boundary apart
/// (`DeviceLocation.usableAccuracy`): a 60 m circle on a 40 m strip says
/// nothing about which strip.
enum StandingIn {
    /// Every parcel's outlines, built once per set of parcels: a fix arrives
    /// every few metres and `mapPolygons` builds new polygons each call.
    static func outlines(_ parcels: [Parcel]) -> [String: [MKPolygon]] {
        var byID: [String: [MKPolygon]] = [:]
        for parcel in parcels where byID[parcel.id] == nil {
            byID[parcel.id] = parcel.geometry?.mapPolygons ?? []
        }
        return byID
    }

    /// The parcel under the position, or nil off every parcel, or on a fix
    /// too rough to say.
    static func parcel(at position: CLLocation?, in parcels: [Parcel],
                       outlines: [String: [MKPolygon]]) -> Parcel? {
        guard let position, position.horizontalAccuracy >= 0,
              position.horizontalAccuracy <= DeviceLocation.usableAccuracy else { return nil }
        let point = MKMapPoint(position.coordinate)
        return parcels
            .filter { parcel in (outlines[parcel.id] ?? []).contains { TreatmentPlace.contains($0, point) } }
            .min { ($0.areaHa ?? .infinity) < ($1.areaHa ?? .infinity) }
    }

    /// What the label says, in the words a parcel's row uses.
    static func sentence(_ parcel: Parcel) -> String {
        "Намирате се в «\(parcel.name)»"
    }
}

/// «Намирате се в „…“» over a farm map, while the phone stands in one of its
/// parcels; nothing otherwise. A separate element from the map, which is a
/// picture to VoiceOver, so the one thing the dot says is said in words too.
struct StandingInLabel: View {
    let parcels: [Parcel]

    @State private var location = DeviceLocation.shared
    @State private var outlines: [String: [MKPolygon]] = [:]

    var body: some View {
        Group {
            if let here = StandingIn.parcel(at: location.position, in: parcels, outlines: outlines) {
                Label(StandingIn.sentence(here), systemImage: "location.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.Surface.bar, in: Capsule())
                    .overlay { Capsule().strokeBorder(Palette.Surface.edge, lineWidth: 1) }
                    .padding(10)
                    .accessibilityElement(children: .combine)
            } else {
                // Something, so the `.task` below runs: on an empty Group it
                // never would, and the outlines it builds are what makes the
                // label appear at all (#428).
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task(id: parcels.map(\.id)) { outlines = StandingIn.outlines(parcels) }
    }
}
