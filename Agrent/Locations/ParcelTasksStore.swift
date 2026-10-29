import Foundation
import Observation

/// A parcel's tasks (#462), cache-first like the archive beside them. ONE
/// store, owned by the parcel's screen and handed to the list its card
/// opens, so the card cannot count tasks the list does not show.
@MainActor
@Observable
final class ParcelTasksStore {
    private(set) var state: LoadState<ParcelTasks> = .loading
    private let parcelID: String

    init(parcelID: String) { self.parcelID = parcelID }

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(WorkItemAPI.parcelTasksPath(parcelID)) { data in
            ParcelTasks(try await WorkItemAPI.decodeList(from: data))
        } publish: { [weak self] in self?.state = $0 }
    }
}
