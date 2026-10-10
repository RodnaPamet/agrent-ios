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
    ///
    /// Again, though, when the last attempt fell short: it failed, a block's
    /// parcels were missing, or the sheet closed before it finished. A sheet
    /// that kept a half-read list for the rest of the screen's life would
    /// keep a crop missing that one more look could find.
    func load() async {
        if blocks.value != nil, crops != nil, !cropsIncomplete { return }
        if blocks.value == nil { blocks = .loading }
        crops = nil
        let locations = await CachedResource.load(LocationsAPI.listPath) { data in
            try await LocationsAPI.decodeList(from: data)
        }
        // A closed sheet cancels its `.task`. A cancelled read answers with
        // a failure or a fallback, and that is not this farm's answer, so it
        // writes nothing. The next opening asks again.
        guard !Task.isCancelled else { return }
        switch locations {
        case .loaded(let rows, let freshness):
            let found = JournalFilter.Block.options(from: rows)
            blocks = .loaded(found, freshness)
            let read = await Self.parcels(in: found.map(\.id))
            guard !Task.isCancelled else { return }
            crops = JournalFilter.Crop.options(from: read.parcels)
            cropsIncomplete = read.failed > 0
        case .failed(let message):
            blocks = .failed(message)
            crops = []
        case .loading:
            break
        }
    }

    /// Every block's parcels. A block whose parcels cannot be read is
    /// counted, not hidden.
    ///
    /// At most `parallelReads` at a time. A farm with forty blocks would
    /// otherwise send forty requests at once, and on a field's connection
    /// they starve one another and time out together (`OfflinePrefetch`
    /// reads them one by one for the same reason). As each read lands, the
    /// next starts.
    nonisolated private static func parcels(in blockIDs: [String]) async -> (parcels: [Parcel], failed: Int) {
        await withTaskGroup(of: [Parcel]?.self) { group in
            var pending = blockIDs.makeIterator()
            for _ in 0..<parallelReads {
                guard let id = pending.next() else { break }
                group.addTask { await parcels(of: id) }
            }
            var all: [Parcel] = []
            var failed = 0
            for await found in group {
                if let found { all += found } else { failed += 1 }
                if let id = pending.next() { group.addTask { await parcels(of: id) } }
            }
            return (all, failed)
        }
    }

    nonisolated private static let parallelReads = 4

    /// One block's parcels: the server's, else the cached copy, else nil.
    nonisolated private static func parcels(of blockID: String) async -> [Parcel]? {
        await CachedResource.load(LocationsAPI.parcelsPath(blockID)) { data in
            try await LocationsAPI.decodeParcels(from: data)
        }.value?.parcels
    }
}
