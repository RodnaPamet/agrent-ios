import MapKit
import SwiftUI

/// A task's parcels on a map, read-only (agrent-ios#177).
///
/// ── SwiftUI's `Map`, not `SatelliteParcelMap` ──
///
/// The location screen's map is an `MKMapView` because it lays vegetation
/// index tiles under its outlines, and SwiftUI's MapKit has no tile overlay.
/// This map has no tiles — Apple's imagery and the outlines, nothing else —
/// which is what `Map` and `MapPolygon` do with no coordinator to keep in
/// step. The outlines come from the same `ParcelGeometry.mapPolygons`, so the
/// holes, the axis order and the rule about degenerate rings are the location
/// map's.
///
/// ── Still, inside a scroll view ──
///
/// No pan, no zoom. In a `ScrollView` a map that takes the drag steals the
/// page's scroll, and the camera already frames the task's parcels, which is
/// what this map is for. The location screen is where a farm is explored.
struct TaskParcelMap: View {
    let content: TaskParcelMapContent

    /// The states, explained under the map. Off for a plain set of linked
    /// parcels, where every outline means the same thing.
    var showsLegend = true

    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            map
            if showsLegend { legend }
            if let note = TaskParcelMapContent.undrawableNote(content.undrawable) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var map: some View {
        Map(initialPosition: .region(content.region), interactionModes: []) {
            ForEach(content.context) { parcel in
                ForEach(Array(polygons(parcel).enumerated()), id: \.offset) { _, polygon in
                    MapPolygon(polygon)
                        .foregroundStyle(Color.clear)
                        .stroke(Palette.Map.TaskParcels.context, lineWidth: 1)
                }
            }
            ForEach(content.marked) { item in
                ForEach(Array(polygons(item.parcel).enumerated()), id: \.offset) { _, polygon in
                    MapPolygon(polygon)
                        .foregroundStyle(fill(item.mark))
                        .stroke(stroke(item.mark), style: strokeStyle(item.mark))
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        // Taller with the text, so the map keeps its share of a page whose
        // words have grown — capped, so at the accessibility sizes it does not
        // push the lines it explains off the first screen.
        .frame(height: min(scaledHeight, 360))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // An image to VoiceOver, said as one sentence — see `spokenSummary`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.spokenSummary)
        .accessibilityAddTraits(.isImage)
    }

    private var legend: some View {
        AdaptiveRow(spacing: 14) {
            ForEach(content.legend, id: \.self) { mark in
                Label {
                    Text(mark.label)
                } icon: {
                    swatch(mark)
                }
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
            }
        }
        // The map's own label already says every parcel's state by name; the
        // legend explains colours, which is information VoiceOver never gets.
        .accessibilityHidden(true)
    }

    /// The parcel's mark as the map draws it, on a ground as dark as the
    /// imagery the colours were chosen for — the skipped grey would vanish
    /// against the light page otherwise.
    private func swatch(_ mark: TaskParcelMark) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fill(mark))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(stroke(mark), style: StrokeStyle(lineWidth: 2, dash: mark == .skipped ? [3, 2] : []))
            }
            .padding(3)
            .frame(width: 24, height: 18)
            .background(Palette.Map.TaskParcels.swatchGround, in: RoundedRectangle(cornerRadius: 4))
    }

    private func polygons(_ parcel: Parcel) -> [MKPolygon] {
        parcel.geometry?.mapPolygons ?? []
    }

    private func fill(_ mark: TaskParcelMark) -> Color {
        switch mark {
        case .pending, .linked:
            // Light, so the field under it still shows — and heavier with
            // Increase Contrast, where the fill is what separates the states.
            Palette.Map.TaskParcels.marked.opacity(
                contrast == .increased ? 0.5 : Palette.Map.TaskParcels.markedFillOpacity)
        case .done:
            Palette.Map.TaskParcels.done.opacity(Palette.Map.fillOpacity(contrast))
        case .skipped:
            .clear
        }
    }

    private func stroke(_ mark: TaskParcelMark) -> Color {
        switch mark {
        case .pending, .linked: Palette.Map.TaskParcels.marked
        case .done: Palette.Map.TaskParcels.done
        case .skipped: Palette.Map.TaskParcels.skipped
        }
    }

    /// Dashed for skipped: the non-colour channel the location map uses too.
    private func strokeStyle(_ mark: TaskParcelMark) -> StrokeStyle {
        let width = Palette.Map.strokeWidth(contrast)
        return mark == .skipped
            ? StrokeStyle(lineWidth: width, dash: Palette.Map.dash)
            : StrokeStyle(lineWidth: width)
    }
}
