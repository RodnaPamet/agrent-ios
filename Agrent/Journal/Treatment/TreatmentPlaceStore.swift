import Foundation
import MapKit
import Observation

/// The farm's crops and their parcels, for «Ново мероприятие»'s second step.
///
/// ── From the routes the app already reads ──
///
/// There is no farm-wide parcels route: parcels are listed per block
/// (`/locations/{id}/parcels`), and agri-saas #1740 asks for one. Until it
/// exists, the blocks are read and then each block's parcels — together, not
/// one after another, because on a field connection N round trips in a row
/// is what makes a screen slow — through the same cached routes the map
/// uses, so this works offline from the cache.
///
/// A block whose parcels cannot be read is counted, not hidden: its parcels
/// are missing from every crop, and the screen says so rather than offering
/// a list that looks whole.
///
/// Loaded by the FLOW, as step one opens, so the parcels are usually in hand
/// by «Напред», and so leaving step two does not cancel a load half-way.
@Observable
@MainActor
final class TreatmentPlaceStore {
    private(set) var state: LoadState<[TreatmentPlace.Crop]> = .loading
    /// Blocks whose parcels could not be read.
    private(set) var unreadBlocks = 0
    /// Every parcel's outlines, built once per load — see
    /// `TreatmentPlace.outlines`.
    private(set) var outlines: [String: [MKPolygon]] = [:]

    typealias LoadBlocks = @Sendable @MainActor () async -> LoadState<[Location]>
    typealias LoadParcels = @Sendable @MainActor (String) async -> LoadState<ParcelsResponse>

    private let loadBlocks: LoadBlocks
    private let loadParcels: LoadParcels

    init(
        loadBlocks: @escaping LoadBlocks = {
            await CachedResource.load(LocationsAPI.listPath) { try await LocationsAPI.decodeList(from: $0) }
        },
        loadParcels: @escaping LoadParcels = { id in
            await CachedResource.load(LocationsAPI.parcelsPath(id)) { try await LocationsAPI.decodeParcels(from: $0) }
        }
    ) {
        self.loadBlocks = loadBlocks
        self.loadParcels = loadParcels
    }

    func load() async {
        if state.value == nil { state = .loading }
        let blocks: [Location]
        var oldest: Date?
        switch await loadBlocks() {
        case .loaded(let value, let freshness):
            blocks = value
            if case .stale(let since) = freshness { oldest = since }
        case .failed(let message):
            guard !Task.isCancelled else { return }
            state = .failed(message)
            return
        case .loading:
            return
        }
        guard !Task.isCancelled else { return }

        // Together, and put back in the blocks' order: the order decides which
        // spelling of a crop is met first, and so how it is labelled.
        let loadParcels = self.loadParcels
        let answers = await withTaskGroup(of: (Int, LoadState<ParcelsResponse>).self) { group in
            for (index, block) in blocks.enumerated() {
                group.addTask { (index, await loadParcels(block.id)) }
            }
            var collected: [(Int, LoadState<ParcelsResponse>)] = []
            for await answer in group { collected.append(answer) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // A load the person walked away from publishes nothing: its requests
        // came back cancelled, and would read as blocks that failed.
        guard !Task.isCancelled else { return }

        var read: [(Location, [Parcel])] = []
        var unread = 0
        var firstFailure: String?
        for (block, answer) in zip(blocks, answers) {
            switch answer {
            case .loaded(let response, let freshness):
                read.append((block, response.parcels))
                if case .stale(let since) = freshness { oldest = min(oldest ?? since, since) }
            case .failed(let message):
                unread += 1
                firstFailure = firstFailure ?? message
            case .loading:
                unread += 1
            }
        }
        unreadBlocks = unread
        // Every block unread is a failure to read the farm, not a farm with
        // no crops — said as the first block's error was.
        if !blocks.isEmpty, read.isEmpty {
            state = .failed(firstFailure ?? UserMessage.statusText(503))
            return
        }
        let crops = TreatmentPlace.crops(read)
        outlines = TreatmentPlace.outlines(crops)
        // The OLDEST copy among them is the age of the list.
        state = .loaded(crops, oldest.map { .stale(since: $0) } ?? .fresh)
    }
}
