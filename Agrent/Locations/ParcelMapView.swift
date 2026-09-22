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
        .navigationTitle(useSchematic ? "" : location.name)
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

    /// The location's identity, over the map rather than in the navigation
    /// bar, as the reference artboard places it.
    ///
    /// NOT A SEARCH FIELD, though it reads like one at a glance — a white
    /// pill floating over a map with an icon on the left is a familiar
    /// shape. There is no input here: a pin, the location's name, and how
    /// many parcels it holds. If search is wanted it is a separate feature
    /// and a separate conversation, because searching four parcels is not
    /// obviously worth a control.
    ///
    /// It sits over the map because on schematic the map has no imagery to
    /// obscure, and putting the name here frees the navigation bar to carry
    /// only the way back.
    @ViewBuilder
    private func locationCard(_ response: ParcelsResponse) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(Palette.accent)
            Text(location.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("^[\(response.parcels.count) парцела](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

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
    }

    private func swatch(_ color: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.85))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            dashed ? Palette.Map.fallowStroke : Palette.Map.sownStroke,
                            style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : [])
                        )
                )
            Text(label).font(.subheadline).foregroundStyle(.primary)
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
                .overlay(alignment: .top) { locationCard(response) }
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
    private func parcelList(_ response: ParcelsResponse, drawable: [Parcel]) -> some View {
        List {
            Section("Парцели") {
                ForEach(response.parcels) { parcel in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parcel.name).font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                if let crop = parcel.cropType { Text(crop) }
                                if let area = parcel.areaHa {
                                    if parcel.cropType != nil { Text("·") }
                                    Text("\(Num.text(area)) ха")
                                }
                                if parcel.hasActiveLease == true {
                                    Text("·"); Text("под аренда")
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !parcel.isDrawable {
                            // Says WHY it is absent from the map. A parcel
                            // silently missing reads as lost data — but an
                            // outline the server never had is not a fault, so
                            // it is stated, not warned about.
                            Label("без очертание", systemImage: "questionmark.square.dashed")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Без географско очертание")
                        }
                    }
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
