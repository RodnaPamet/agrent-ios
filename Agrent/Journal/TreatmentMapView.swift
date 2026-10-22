import MapKit
import SwiftUI

/// «Виж на картата» on a recorded treatment (#399, owner 2026-10-22): which
/// parcels were treated, and where. All of them highlighted on the map, with
/// the target button to jump between them (#398), and listed by block below.
/// A row frames its parcel, so the map can be walked from the list as well.
struct TreatmentMapView: View {
    let title: String
    @State private var store: TreatmentMapStore
    @State private var camera: MapCameraPosition = .region(.bulgaria)
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledMapHeight: CGFloat = 280

    /// From the journal: read by the treatment's handle.
    init(handle: String, title: String) {
        self.title = title
        _store = State(initialValue: TreatmentMapStore(handle: handle))
    }

    /// From the saved screen, which holds the parcels already.
    init(fields: [TreatmentPlace.Field], title: String) {
        self.title = title
        _store = State(initialValue: TreatmentMapStore(fields: fields))
    }

    /// Room for the list at the accessibility sizes, as on step two.
    private var mapHeight: CGFloat { typeSize.isAccessibilitySize ? 160 : min(scaledMapHeight, 360) }

    var body: some View {
        content
            .pageBackground()
            .inlineTitle(title)
            .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.load() }
        case .loaded(let fields, _):
            VStack(spacing: 0) {
                if fields.contains(where: { $0.parcel.isDrawable }) {
                    TreatmentParcelMap(fields: fields, outlines: store.outlines,
                                       chosen: Set(fields.map(\.id)), camera: $camera, onToggle: nil)
                        .frame(height: mapHeight)
                }
                list(fields)
            }
            .onChange(of: fields.map(\.id), initial: true) { _, _ in
                camera = .region(MKCoordinateRegion(fitting: fields.map(\.parcel)) ?? .bulgaria)
            }
        }
    }

    private func list(_ fields: [TreatmentPlace.Field]) -> some View {
        List {
            Section {
                ForEach(fields) { row($0) }
            } footer: {
                SectionFooter(footer(fields))
            }
        }
        .pageBackground()
    }

    private func row(_ field: TreatmentPlace.Field) -> some View {
        let area = field.parcel.areaHa.map { Area(hectares: $0) }
        return Button {
            if let region = MKCoordinateRegion(fitting: [field.parcel]) { camera = .region(region) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.parcel.name)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                MetaRow {
                    Text(field.blockName)
                    if let area { MetaSeparator(); Text(area.text) }
                }
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!field.parcel.isDrawable)
        .cardRow()
        .accessibilityLabel(A11y.sentence([field.parcel.name, field.blockName, area?.spoken]))
        .accessibilityHint(field.parcel.isDrawable ? "Показва парцела на картата" : "")
        .accessibilityInputLabels([field.parcel.name])
    }

    private func footer(_ fields: [TreatmentPlace.Field]) -> String {
        var lines = [Plural.bg(fields.count, "парцел", "парцела") + "."]
        let undrawn = fields.filter { !$0.parcel.isDrawable }.count
        if undrawn > 0 {
            lines.append(undrawn == 1
                ? "1 парцел няма очертание и не е на картата."
                : "\(undrawn) парцела нямат очертание и не са на картата.")
        }
        return lines.joined(separator: " ")
    }
}

extension TreatmentMapView {
    /// «Третирани парцели» or «Наторени парцели», the ДНЕВНИК's own words for
    /// what was done to them.
    static func title(for kind: TreatmentDraft.Kind?) -> String {
        kind == .fertilize ? "Наторени парцели" : "Третирани парцели"
    }

    /// The button that opens it, the same on the journal's entry and the
    /// saved screen.
    static let buttonTitle = "Виж на картата"
}
