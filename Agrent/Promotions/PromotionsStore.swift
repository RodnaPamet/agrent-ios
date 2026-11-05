import Foundation
import Observation

/// «Промоции»'s list (#528): cache first, then the server, revalidated by its
/// ETag, so a relaunch on a weak signal shows the offers it last saw.
@MainActor
@Observable
final class PromotionsStore {
    private(set) var state: LoadState<[PromotionsAPI.Promotion]> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(PromotionsAPI.listPath) { data in
            try await PromotionsAPI.decodeList(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }

    /// Asked: the card says so at once, and the next read agrees.
    func markRequested(_ id: String) {
        guard case .loaded(var items, let freshness) = state,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].hasRequested = true
        state = .loaded(items, freshness)
    }
}
