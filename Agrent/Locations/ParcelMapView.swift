import MapKit
import SwiftUI

struct ParcelMapView: View {
    let location: Location

    @State private var store: ParcelsStore

    /// Remembered per user, and SCHEMATIC BY DEFAULT.
    ///
    /// The default is the decision, not the toggle. Schematic's first frame
    /// needs no network, so a farmer opening this with no coverage sees their
    /// fields rather than grey tiles — and that is the situation this screen
    /// exists for. MapKit is the deliberate second look, for geographic
    /// context, which is when imagery is genuinely what you want. Neither is
    /// a fallback for the other.
    ///
    /// One button, two states. MapKit offers standard/hybrid/satellite for
    /// free and adding them would turn this into a picker, which is the one
    /// thing it was asked not to become.
    @AppStorage("locations.useSchematicMap") private var useSchematic = true

    @Environment(\.colorSchemeContrast) private var contrast

    init(location: Location) {
        self.location = location
        _store = State(initialValue: ParcelsStore(locationID: location.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let age = store.state.freshness?.ageDescription {
                StaleBanner(age: age)
            }
            content
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    useSchematic.toggle()
                } label: {
                    Label(
                        useSchematic ? "Сателит" : "Схема",
                        systemImage: useSchematic ? "globe.europe.africa" : "square.on.square.dashed"
                    )
                }
                .accessibilityHint(useSchematic
                    ? "Превключва към сателитна карта"
                    : "Превключва към схематична карта")
            }
        }
        .task { if store.state.value == nil { await store.load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let response, _):
            let drawable = response.parcels.filter(\.isDrawable)
            VStack(spacing: 0) {
                map(response, drawable: drawable)
                    .frame(maxHeight: .infinity)
                if useSchematic && !drawable.isEmpty { legend }
                parcelList(response, drawable: drawable)
            }
        }
    }

    // MARK: - Map

    /// Only for the schematic view. On satellite the fills sit over imagery
    /// and the colours are not the only cue, but here they carry the whole
    /// meaning, so the key has to be on screen.
    private var legend: some View {
        HStack(spacing: 16) {
            swatch(Palette.Map.sownFill, "Засят", dashed: false)
            swatch(Palette.Map.fallowFill, "Угар", dashed: true)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        // The swatches ARE the content here; spoken, they are two unlabelled
        // rectangles followed by two words. Said once, as what the key means.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Легенда: плътно зелено е засят парцел, пунктирано светло е угар.")
    }

    /// The key must track the map. A legend showing a 0.85 tint beside a map
    /// drawing a near-solid fill is a key to a different picture, and it is
    /// exactly the person relying on the key who would be misled.
    private func swatch(_ color: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(contrast == .increased ? 0.95 : 0.85))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            dashed ? Palette.Map.fallowStroke : Palette.Map.sownStroke,
                            style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : [])
                        )
                )
            Text(label).font(.footnote).foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func map(_ response: ParcelsResponse, drawable: [Parcel]) -> some View {
        if drawable.isEmpty {
            EmptyState(
                "Няма очертания",
                icon: "map",
                message: "Парцелите съществуват, но нямат географски очертания."
            )
        } else if useSchematic, let box = response.bounds ?? location.boundsJson {
            SchematicParcelMap(parcels: drawable, bounds: box)
        } else {
            // Camera from `bounds` when the server sent one, otherwise from
            // the location's own boundsJson. Both are [minLon, minLat, …] and
            // both are read through BoundingBox's NAMED fields — never
            // positionally, which is how the camera ends up in the Red Sea.
            Map(initialPosition: .region((response.bounds ?? location.boundsJson)?.region
                ?? MKCoordinateRegion(.world))) {
                ForEach(drawable) { parcel in
                    // One MKPolygon per GeoJSON polygon, holes already carried
                    // as interiorPolygons — see ParcelGeometry.mapPolygons.
                    ForEach(Array((parcel.geometry?.mapPolygons ?? []).enumerated()), id: \.offset) { _, polygon in
                        MapPolygon(polygon)
                            .foregroundStyle(.green.opacity(0.35))
                            .stroke(.green, lineWidth: 2)
                    }
                }
            }
            .mapStyle(.hybrid)
        }
    }

    // MARK: - Parcels

    @ViewBuilder
    private func parcelRow(_ parcel: Parcel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(parcel.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    if let crop = CommodityName.freeText(parcel.cropType) { Text(crop) }
                    if let area = parcel.areaHa {
                        if parcel.cropType != nil { Text("·") }
                        Text("\(Num.text(area)) ха")
                    }
                    if parcel.hasActiveLease == true {
                        Text("·"); Text("под аренда")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !parcel.isDrawable {
                // Says WHY it is absent from the map. A parcel silently
                // missing reads as lost data — but an outline the server
                // never had is not a fault, so it is stated, not warned
                // about.
                Label("без очертание", systemImage: "questionmark.square.dashed")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        // Up to three `·` separators in one row, so this was the worst of
        // them: "Пшеница middle dot 12,4 ха middle dot под аренда". Spoken
        // from the values, with the units said in full — "ха" is read as a
        // word, not as "хектара".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            parcel.name,
            CommodityName.freeText(parcel.cropType),
            parcel.areaHa.map { "\(Num.text($0)) хектара" },
            parcel.hasActiveLease == true ? "под аренда" : nil,
            // The icon carried this and only as an icon label. It belongs in
            // the row's sentence: a parcel absent from the map is the thing
            // an operator most needs told, and it is invisible in a list.
            parcel.isDrawable ? nil : "без географско очертание",
        ]))
    }

    @ViewBuilder
    private func parcelList(_ response: ParcelsResponse, drawable: [Parcel]) -> some View {
        List {
            Section(header: Text(Plural.bg(response.parcels.count, "парцел", "парцела"))) {
                ForEach(response.parcels) { parcel in
                    parcelRow(parcel)
                }
            }
            if drawable.count != response.parcels.count {
                RefusalNote(
                    text: "\(response.parcels.count - drawable.count) парцела без очертания не се показват на картата.",
                    icon: "map"
                )
            }
        }
        .frame(maxHeight: 260)
    }
}
