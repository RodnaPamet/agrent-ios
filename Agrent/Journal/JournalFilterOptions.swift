import Foundation
import Observation

/// What the Дневник's filter sheet can offer: the farm's blocks, and the
/// crops on their parcels (#252).
///
/// ── The crops come from the farm's own parcels ──
///
/// Not from a fixed list. The web's filter offers six catalogue words, but the
/// server compares `cropType` exactly, and the farm's parcels hold whatever was
/// written to them. Offering what is actually stored means every choice can
/// match something, and a farm sees its own crops, not a catalogue.
///
/// The parcels are read through `CachedResource.load`, as `OfflinePrefetch`
/// reads them on launch. Usually that means a cache already warm and a
/// revalidation that costs no body.
@Observable
@MainActor
final class JournalFilterOptions {
    private(set) var blocks: LoadState<[JournalFilter.Block]> = .loading

    /// Nil while the parcels are read.
    private(set) var crops: [JournalFilter.Crop]?

    /// Some block's parcels could not be read, from the server or the cache,
    /// so `crops` may be short of a crop that block grows.
    private(set) var cropsIncomplete = false

    /// Once per screen. Blocks and crops change rarely, and a sheet that
    /// asked again on every opening would make each look at the filter pay
    /// for a round trip per block.
    func load() async {
        guard blocks.value == nil else { return }
        let locations = await CachedResource.load(LocationsAPI.listPath) { data in
            try await LocationsAPI.decodeList(from: data)
        }
        switch locations {
        case .loaded(let rows, let freshness):
            let found = JournalFilter.Block.options(from: rows)
            blocks = .loaded(found, freshness)
            let read = await Self.cropTypes(in: found.map(\.id))
            crops = JournalFilter.Crop.options(from: read.cropTypes)
            cropsIncomplete = read.failed > 0
        case .failed(let message):
            blocks = .failed(message)
            crops = []
        case .loading:
            break
        }
    }

    /// Every parcel's `cropType`, across the blocks. Each block's request
    /// runs concurrently with the others. A block whose parcels cannot be
    /// read is counted, not hidden.
    nonisolated private static func cropTypes(in blockIDs: [String]) async -> (cropTypes: [String?], failed: Int) {
        await withTaskGroup(of: [String?]?.self) { group in
            for id in blockIDs {
                group.addTask {
                    let parcels = await CachedResource.load(LocationsAPI.parcelsPath(id)) { data in
                        try await LocationsAPI.decodeParcels(from: data)
                    }
                    return parcels.value?.parcels.map(\.cropType)
                }
            }
            var all: [String?] = []
            var failed = 0
            for await found in group {
                if let found { all += found } else { failed += 1 }
            }
            return (all, failed)
        }
    }
}
