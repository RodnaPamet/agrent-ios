import SwiftUI

struct LocationsView: View {
    @State private var store = LocationsStore()

    var body: some View {
        NavigationStack {
            // Chrome in a VStack above the scrollable — Борса's
            // arrangement, the one confirmed by use. See
            // `JournalListView` for why this is no longer a
            // `safeAreaInset(edge: .top)`.
            VStack(spacing: 0) {
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                content
            }
            .pageBackground()
            .navigationTitle("Локации")
            .appMenu()
            .task {
                if store.state.value == nil { await store.load() }
            }
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
            EmptyState(
                "Няма локации",
                icon: "map",
                message: "Това стопанство още няма въведени локации."
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
                                Text(Plural.bg(count, "парцел", "парцела"))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    // `.combine` was here and it read the `·` aloud as
                    // "middle dot". Built from the values instead, and
                    // covering the name too, so the row is one stop rather
                    // than a heading followed by a combined fragment.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11y.sentence([
                        location.name,
                        location.kind,
                        location.parcelCount.map { Plural.bg($0, "парцел", "парцела") },
                    ]))
                }
                // On the ROW — see JournalListView.
                .listRowBackground(Palette.Surface.card)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await PullToRefresh.bounded { await store.refresh() } }
        }
    }
}
