import Foundation
import MapKit
import Observation

/// The farm's crops, and a crop's parcels once it is chosen, for
/// «Ново мероприятие»'s second step.
///
/// ── From `/parcels/by-crop` (agri-saas #1746) ──
///
/// The crop list first — values, counts, no geometry — and then one crop's
/// parcels with their blocks and outlines when the crop is chosen. The route
/// was built for this screen; before it, the screen read every block and
/// then each block's parcels, one request per block. Both answers are cached
/// like every other read, so the step works offline from the cache.
///
/// A crop with more than one stored spelling («Canola», «Rapeseed») is
/// asked for once per spelling, together, and its parcels merged.
///
/// The crop list is loaded by the FLOW as step one opens, so it is usually in
/// hand by «Напред», and so leaving step two does not cancel it.
@Observable
@MainActor
final class TreatmentPlaceStore {
    private(set) var state: LoadState<[TreatmentPlace.Crop]> = .loading
    /// Each crop's parcels, by the crop's key, once asked for.
    private(set) var fields: [String: LoadState<[TreatmentPlace.Field]>] = [:]
    /// Every loaded parcel's outlines, built once per load — see
    /// `TreatmentPlace.outlines`.
    private(set) var outlines: [String: [MKPolygon]] = [:]

    typealias LoadCrops = @Sendable @MainActor () async -> LoadState<ParcelsByCropAPI.CropTotals>
    typealias LoadCrop = @Sendable @MainActor (String) async -> LoadState<ParcelsByCropAPI.CropParcels>

    private let loadCrops: LoadCrops
    private let loadCrop: LoadCrop

    init(
        loadCrops: @escaping LoadCrops = {
            await CachedResource.load(ParcelsByCropAPI.path) { try await ParcelsByCropAPI.decodeTotals(from: $0) }
        },
        loadCrop: @escaping LoadCrop = { crop in
            await CachedResource.load(ParcelsByCropAPI.path(crop: crop)) {
                try await ParcelsByCropAPI.decodeParcels(from: $0)
            }
        }
    ) {
        self.loadCrops = loadCrops
        self.loadCrop = loadCrop
    }

    func load() async {
        if state.value == nil { state = .loading }
        let answer = await loadCrops()
        // A load the person walked away from publishes nothing.
        guard !Task.isCancelled else { return }
        switch answer {
        case .loaded(let totals, let freshness):
            state = .loaded(TreatmentPlace.crops(totals.crops), freshness)
        case .failed(let message):
            state = .failed(message)
        case .loading:
            return
        }
    }

    /// The crop's parcels — every stored spelling of it, together. All or
    /// nothing: a crop shown with some of its parcels missing would read as
    /// the whole crop, and a spray recorded from it would leave fields out.
    func loadFields(for crop: TreatmentPlace.Crop) async {
        if fields[crop.key]?.value == nil { fields[crop.key] = .loading }
        let loadCrop = self.loadCrop
        let answers = await withTaskGroup(of: (Int, LoadState<ParcelsByCropAPI.CropParcels>).self) { group in
            for (index, value) in crop.values.enumerated() {
                group.addTask { (index, await loadCrop(value)) }
            }
            var collected: [(Int, LoadState<ParcelsByCropAPI.CropParcels>)] = []
            for await answer in group { collected.append(answer) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !Task.isCancelled else { return }

        var read: [ParcelsByCropAPI.CropParcels] = []
        var oldest: Date?
        for answer in answers {
            switch answer {
            case .loaded(let parcels, let freshness):
                read.append(parcels)
                if case .stale(let since) = freshness { oldest = min(oldest ?? since, since) }
            case .failed(let message):
                // A crop already in hand keeps what it showed: the cache
                // fallback failed too, and an error over a working list
                // would take the list away.
                if fields[crop.key]?.value == nil { fields[crop.key] = .failed(message) }
                return
            case .loading:
                return
            }
        }
        let loaded = TreatmentPlace.fields(read)
        outlines.merge(TreatmentPlace.outlines(loaded)) { _, new in new }
        // The OLDEST copy among them is the age of the list.
        fields[crop.key] = .loaded(loaded, oldest.map { .stale(since: $0) } ?? .fresh)
    }
}
