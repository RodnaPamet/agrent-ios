import Foundation
import Observation

@Observable
@MainActor
final class LocationsStore {
    private(set) var state: LoadState<[Location]> = .loading

    func load() async { await load(showCachedFirst: true) }

    /// Pull-to-refresh. The screen already has content, so the cached copy
    /// is NOT re-published under the reader's finger — that re-renders the
    /// list mid-gesture and reads as the refresh glitching. They asked for
    /// fresh; give them fresh, or the error.
    func refresh() async { await load(showCachedFirst: false) }

    private func load(showCachedFirst: Bool) async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(
            LocationsAPI.listPath, showCachedFirst: showCachedFirst
        ) { data in
            try await LocationsAPI.decodeList(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}

@Observable
@MainActor
final class ParcelsStore {
    private(set) var state: LoadState<ParcelsResponse> = .loading
    private let locationID: String

    init(locationID: String) { self.locationID = locationID }

    func load() async {
        if state.value == nil { state = .loading }
        let path = LocationsAPI.parcelsPath(locationID)
        await CachedResource.loadShowingCacheFirst(path) { data in
            try await LocationsAPI.decodeParcels(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }

    /// A rename shows at once (#667); the next read confirms it.
    func applyNickname(_ displayName: String?, to parcelID: String) {
        guard case .loaded(var response, let freshness) = state,
              let index = response.parcels.firstIndex(where: { $0.id == parcelID }) else { return }
        response.parcels[index].displayName = displayName
        state = .loaded(response, freshness)
    }
}
