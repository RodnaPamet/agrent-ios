import Foundation
import Observation

/// A parcel and its reading, once one arrives.
struct RiskRow: Identifiable, Equatable, Sendable {
    let parcel: Parcel
    var risk: ParcelRisk?
    var failure: String?

    var id: String { parcel.id }

    /// Worst first, unread last, then by name so the order is stable
    /// between loads rather than shuffling as readings arrive.
    var sortKey: (Int, String) {
        ((risk?.overall ?? .unknown).severityOrder, parcel.name)
    }
}

@Observable
@MainActor
final class FarmRiskStore {
    private(set) var locations: LoadState<[Location]> = .loading
    private(set) var parcels: LoadState<[RiskRow]> = .loading
    private(set) var isReadingRisks = false

    var selected: Location?

    /// Parcels already asked about. Read from the server, never remembered
    /// locally — the web page tracked this in component state, it died on
    /// unmount, and an operator got a refusal for retrying something they
    /// had no way to see they had done.
    private(set) var askedParcelIDs: Set<String> = []

    func loadLocations() async {
        await CachedResource.loadShowingCacheFirst(LocationsAPI.listPath) { data in
            try await LocationsAPI.decodeList(from: data)
        } publish: { [weak self] in self?.locations = $0 }
        if selected == nil { selected = locations.value?.first }
    }

    func loadParcels() async {
        guard let location = selected else { return }
        if parcels.value == nil { parcels = .loading }
        await CachedResource.loadShowingCacheFirst(
            LocationsAPI.parcelsPath(location.id)
        ) { data in
            try await LocationsAPI.decodeParcels(from: data)
        } publish: { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading:
                self.parcels = .loading
            case .failed(let message):
                self.parcels = .failed(message)
            case .loaded(let response, let freshness):
                // Every parcel appears immediately with no reading, so the
                // list is complete from the first frame and fills in. A
                // farmer sees which fields exist before they see how they
                // are doing, which is the right order — the parcels are
                // the thing they recognise.
                self.parcels = .loaded(
                    response.parcels.map { RiskRow(parcel: $0) }, freshness)
            }
        }
    }

    /// One request per parcel, SEQUENTIALLY, publishing each as it lands.
    ///
    /// Not concurrent: on a weak connection parallel requests compete for
    /// the same scrap of bandwidth and all time out — the same reasoning
    /// as `OfflinePrefetch`. Sequential means the first parcels read
    /// quickly even when the last never does, and the list visibly fills
    /// rather than sitting empty until all of them are in.
    func readRisks() async {
        guard let rows = parcels.value, !isReadingRisks else { return }
        isReadingRisks = true
        defer { isReadingRisks = false }

        for row in rows {
            let path = FarmRiskAPI.analysisPath(row.parcel.id)
            await CachedResource.loadShowingCacheFirst(path) { data in
                try await FarmRiskAPI.decodeAnalysis(from: data)
            } publish: { [weak self] state in
                guard let self, case .loaded(var current, let freshness) = self.parcels,
                      let index = current.firstIndex(where: { $0.id == row.parcel.id })
                else { return }
                switch state {
                case .loaded(let risk, _):
                    current[index].risk = risk
                    current[index].failure = nil
                case .failed(let message):
                    // Keep the parcel; lose only its reading. A field that
                    // vanishes because its analysis failed is worse than a
                    // field with no reading.
                    current[index].failure = message
                case .loading:
                    return
                }
                self.parcels = .loaded(current.sorted { $0.sortKey < $1.sortKey }, freshness)
            }
        }
    }

    func select(_ location: Location) async {
        guard location.id != selected?.id else { return }
        selected = location
        parcels = .loading
        await loadParcels()
        await readRisks()
    }
}
