import Foundation
import Observation

/// A parcel's comments (#465), cache first like its archive. One store for
/// the card on the parcel's screen and the list it opens.
@MainActor
@Observable
final class ParcelCommentsStore {
    private(set) var state: LoadState<ParcelComments> = .loading
    private let parcelID: String

    init(parcelID: String) { self.parcelID = parcelID }

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(ParcelCommentsAPI.path(parcelID)) { data in
            try await ParcelCommentsAPI.decode(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}
