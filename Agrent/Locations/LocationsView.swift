import SwiftUI

struct LocationsView: View {
    @State private var store = LocationsStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                content
            }
            .navigationTitle("Локации")
            .task { if store.state.value == nil { await store.load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let locations, _) where locations.isEmpty:
            ContentUnavailableView(
                "Няма локации",
                systemImage: "map",
                description: Text("Това стопанство още няма въведени локации.")
            )

        case .loaded(let locations, _):
            List(locations) { location in
                NavigationLink {
                    ParcelMapView(location: location)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.name).font(.headline)
                        HStack(spacing: 8) {
                            Text(location.kind)
                            if let count = location.parcelCount {
                                Text("·")
                                Text("^[\(count) парцела](inflect: true)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.vertical, 2)
                }
            }
            .refreshable { await store.load() }
        }
    }
}
