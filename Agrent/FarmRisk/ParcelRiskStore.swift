import Foundation
import Observation

/// One parcel's risk reading, for its own screen (owner, 2026-10-29): the
/// same analysis Риск reads per row (`FarmRiskAPI.analysisPath`), cache
/// first, so a parcel reopened on a bad connection shows its last reading
/// at once and says how old it is.
@MainActor
@Observable
final class ParcelRiskStore {
    private(set) var state: LoadState<ParcelRisk> = .loading
    private let parcelID: String

    init(parcelID: String) {
        self.parcelID = parcelID
    }

    func load() async {
        await CachedResource.loadShowingCacheFirst(FarmRiskAPI.analysisPath(parcelID)) { data in
            try await FarmRiskAPI.decodeAnalysis(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}
