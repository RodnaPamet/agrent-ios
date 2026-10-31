import SwiftUI

/// A block named only by id, from a notification's link (#475): found in the
/// farm's list of blocks, the read Блокове makes and caches, so it opens with
/// no signal on a phone that has opened Блокове before. Then its map.
struct LocationLinkView: View {
    let id: String

    @State private var state: LoadState<[Location]> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Зареждане на блока")
            case .failed(let message):
                ErrorState(message: message) { await load() }
            case .loaded(let blocks, _):
                if let block = blocks.first(where: { $0.id == id }) {
                    ParcelMapView(location: block)
                } else {
                    EmptyState("Блокът не е намерен", icon: "map",
                               message: "Блокът от известието вече не е в стопанството.")
                }
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        await CachedResource.loadShowingCacheFirst(LocationsAPI.listPath) {
            try await LocationsAPI.decodeList(from: $0)
        } publish: { state = $0 }
    }
}
