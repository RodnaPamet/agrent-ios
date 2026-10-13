import MapKit
import SwiftUI

/// The chosen crop's parcels on a map, where a tap on a field toggles it
/// (agrent-ios#293).
///
/// Its own view, so a save starting or failing does not redraw it; and fed
/// the outlines the store built once, so a toggle or a pan does not rebuild
/// every polygon.
///
/// ── Hidden from VoiceOver, on purpose ──
///
/// The map pans, zooms and toggles. Presented as one image, VoiceOver's
/// double-tap would land a tap at its centre — on whichever field is there —
/// and toggle it unannounced. Nothing on it is unique: the list beside it has
/// every parcel by name with its state, and the bar has the total. That is
/// the only reason hiding it is right.
struct TreatmentParcelMap: View {
    let fields: [TreatmentPlace.Field]
    let outlines: [String: [MKPolygon]]
    let chosen: Set<String>
    @Binding var camera: MapCameraPosition
    let onToggle: (String) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    /// One drawn ring of one parcel, flattened so the map's content is a
    /// single `ForEach` — nested, it was too much for the type checker.
    private struct Outline: Identifiable {
        let id: String
        let polygon: MKPolygon
        let picked: Bool
    }

    private var drawn: [Outline] {
        fields.flatMap { field in
            let picked = chosen.contains(field.id)
            return (outlines[field.id] ?? []).enumerated().map { index, polygon in
                Outline(id: "\(field.id)#\(index)", polygon: polygon, picked: picked)
            }
        }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                ForEach(drawn) { outline in
                    MapPolygon(outline.polygon)
                        .foregroundStyle(fill(outline.picked))
                        .stroke(stroke(outline.picked), lineWidth: width(outline.picked))
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local),
                      let hit = TreatmentPlace.fields(at: coordinate, in: fields, outlines: outlines).first
                else { return }
                onToggle(hit.id)
            }
        }
        .accessibilityHidden(true)
    }

    /// Chosen: amber over a light fill, heavier with Increase Contrast. Not
    /// chosen: a THIN outline and no fill — the task map's context line. Amber
    /// and the white outline are close in brightness on the imagery, so the
    /// width and the fill are the channels that do not depend on colour.
    private func fill(_ picked: Bool) -> Color {
        guard picked else { return .clear }
        return Palette.Map.TaskParcels.marked.opacity(contrast == .increased ? 0.5 : 0.35)
    }

    private func stroke(_ picked: Bool) -> Color {
        picked ? Palette.Map.TaskParcels.marked : Palette.Map.TaskParcels.context
    }

    private func width(_ picked: Bool) -> CGFloat {
        picked ? Palette.Map.strokeWidth(contrast) : 1
    }
}
