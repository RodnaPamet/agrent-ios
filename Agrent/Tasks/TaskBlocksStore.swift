import Foundation
import MapKit
import Observation

/// «Нова задача»'s parcels step (#388): the farm's blocks, and each block's
/// parcels as it is chosen.
///
/// By BLOCK (owner, 2026-10-21; first by crop, then changed), so a task that
/// isn't about a crop, such as clearing a canal along a block, still finds
/// its fields. Both reads are the ones Блокове makes, and `OfflinePrefetch`
/// warms both, so the step works with no signal on a phone that has opened
/// the app with signal once. Cache first, like Блокове.
@Observable
@MainActor
final class TaskBlocksStore {
    private(set) var blocks: LoadState<[Location]> = .loading
    /// Each chosen block's parcels, as `TreatmentParcelMap` draws them, by
    /// block id.
    private(set) var fields: [String: LoadState<[TreatmentPlace.Field]>] = [:]
    private(set) var outlines: [String: [MKPolygon]] = [:]

    typealias LoadBlocks = @MainActor (@escaping @MainActor @Sendable (LoadState<[Location]>) -> Void) async -> Void
    typealias LoadParcels = @MainActor (String, @escaping @MainActor @Sendable (LoadState<ParcelsResponse>) -> Void) async -> Void

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
    }

    func loadFields(for block: Location) async {
        if fields[block.id]?.value == nil { fields[block.id] = .loading }
        await loadParcels(block.id) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .loading:
                return
            case .failed(let message):
                // A block already in hand keeps what it showed: an error over
                // a working list would take the list away.
                if self.fields[block.id]?.value == nil { self.fields[block.id] = .failed(message) }
            case .loaded(let response, let freshness):
                let loaded = Self.fields(response.parcels, in: block)
                self.outlines.merge(TreatmentPlace.outlines(loaded)) { _, new in new }
                self.fields[block.id] = .loaded(loaded, freshness)
            }
        }
    }

    /// A block's parcels as the map and the list take them, by name. A name
    /// alone is what a farmer looks for in a list.
    nonisolated static func fields(_ parcels: [Parcel], in block: Location) -> [TreatmentPlace.Field] {
        parcels
            .map { TreatmentPlace.Field(parcel: $0, blockID: block.id, blockName: block.name) }
            .sorted { $0.parcel.name.localizedStandardCompare($1.parcel.name) == .orderedAscending }
    }
}
