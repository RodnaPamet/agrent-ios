import MapKit
import SwiftUI

struct ParcelMapView: View {
    let location: Location

    @State private var store: ParcelsStore

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
                parcelList(response, drawable: drawable)
            }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private func map(_ response: ParcelsResponse, drawable: [Parcel]) -> some View {
        if drawable.isEmpty {
            ContentUnavailableView(
                "Няма очертания",
                systemImage: "map",
                description: Text("Парцелите съществуват, но нямат географски очертания.")
            )
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
