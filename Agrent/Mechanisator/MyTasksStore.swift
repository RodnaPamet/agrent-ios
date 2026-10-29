import Foundation
import Observation

/// The mechanisator's own tasks, under the farm's map (#465). Cache first,
/// as Задачи is, so the list is there with no signal in a field.
@MainActor
@Observable
final class MyTasksStore {
    private(set) var state: LoadState<[WorkItemSummary]> = .loading

    typealias Load = @MainActor (@escaping @MainActor @Sendable (LoadState<[WorkItemSummary]>) -> Void) async -> Void
    private let loadQueue: Load

    init(load: @escaping Load = { publish in
        await CachedResource.loadShowingCacheFirst(FarmTasksAPI.queuePath) {
            try await FarmTasksAPI.decodeQueue(from: $0)
        } publish: { publish($0) }
    }) {
        loadQueue = load
    }

    func load() async {
        if state.value == nil { state = .loading }
        await loadQueue { [weak self] in self?.state = $0 }
    }

    /// The work still to do, in the server's order (soonest due first):
    /// what «Архив» on a parcel's screen leaves out (`isArchived`).
    var current: [WorkItemSummary]? {
        state.value?.filter { !$0.status.isArchived }
    }
}
