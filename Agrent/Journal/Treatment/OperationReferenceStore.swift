import Foundation
import Observation

/// Items and rate units.
///
/// Both are effectively static — `Unit` has no write path and the server
/// caches the list for 24h — so both go through `CachedResource` and are
/// available with no signal, which is the case «Нов запис» is used in.
@Observable
@MainActor
final class OperationReferenceStore {
    private(set) var items: LoadState<[InputItem]> = .loading
    private(set) var units: LoadState<[Unit]> = .loading

    func load() async {
        if items.value == nil {
            await CachedResource.loadShowingCacheFirst(LocationsAPI.itemsPath) {
                try await LocationsAPI.decodeItems(from: $0)
            } publish: { [weak self] in self?.items = $0 }
        }
        if units.value == nil {
            await CachedResource.loadShowingCacheFirst(LocationsAPI.rateUnitsPath) {
                try await LocationsAPI.decodeUnits(from: $0)
            } publish: { [weak self] in self?.units = $0 }
        }
    }
}
