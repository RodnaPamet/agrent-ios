import Foundation
import Observation

/// Every block's parcels, for the mechanisator's whole-farm map (#465,
/// owner 2026-10-29: the whole farm, not one block at a time).
///
/// The reads Блокове makes, one per block, cache first, and warmed by
/// `OfflinePrefetch`, so the map draws with no signal on a phone that has
/// opened the app with signal once. The blocks are read in parallel; a block
/// that fails leaves the others on the map, and says so.
@MainActor
@Observable
final class FarmParcelsStore {
    private(set) var blocks: LoadState<[Location]> = .loading
    /// Each block's parcels, by block id, as they arrive.
    private(set) var parcels: [String: [Parcel]] = [:]
    /// Blocks whose parcels could not be read and were not cached.
    private(set) var failed: Set<String> = []

    typealias LoadBlocks = TaskBlocksStore.LoadBlocks
    typealias LoadParcels = TaskBlocksStore.LoadParcels

    private let loadBlocks: LoadBlocks
    private let loadParcels: LoadParcels

    init(
        loadBlocks: @escaping LoadBlocks = { publish in
            await CachedResource.loadShowingCacheFirst(LocationsAPI.listPath) {
                try await LocationsAPI.decodeList(from: $0)
            } publish: { publish($0) }
        },
        loadParcels: @escaping LoadParcels = { id, publish in
            await CachedResource.loadShowingCacheFirst(LocationsAPI.parcelsPath(id)) {
                try await LocationsAPI.decodeParcels(from: $0)
            } publish: { publish($0) }
        }
    ) {
        self.loadBlocks = loadBlocks
        self.loadParcels = loadParcels
    }

    func load() async {
        if blocks.value == nil { blocks = .loading }
        await loadBlocks { [weak self] in self?.blocks = $0 }
        guard let list = blocks.value else { return }
        await withDiscardingTaskGroup { group in
            for block in list {
                group.addTask { await self.loadParcels(of: block.id) }
            }
        }
    }

    private func loadParcels(of blockID: String) async {
        await loadParcels(blockID) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .loading:
                return
            case .failed:
                // A block already on the map keeps its parcels: an error
                // would take a working map away.
                if self.parcels[blockID] == nil { self.failed.insert(blockID) }
            case .loaded(let response, _):
                self.parcels[blockID] = response.parcels
                self.failed.remove(blockID)
            }
        }
    }

    /// Every block has answered, with its parcels or a failure. The map is
    /// built then, as it fits its camera to the farm once, when it opens.
    var settled: Bool {
        guard let list = blocks.value else { return false }
        return list.allSatisfy { parcels[$0.id] != nil || failed.contains($0.id) }
    }

    /// Every parcel on the farm with the block it is in, which a parcel's
    /// screen needs for «Ново мероприятие». In the blocks' order, then by
    /// name within a block.
    var all: [ParcelInBlock] {
        (blocks.value ?? []).flatMap { block in
            (parcels[block.id] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { ParcelInBlock(locationID: block.id, parcel: $0) }
        }
    }
}
