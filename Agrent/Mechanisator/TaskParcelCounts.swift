import Foundation
import Observation

/// How many of the mechanisator's current tasks touch each parcel: the
/// numbers on the whole-farm map (#465).
///
/// ── One read per task, for now ──
///
/// The queue's rows carry no parcel ids, so each current task's parcels are
/// read from `GET /tasks/{id}/parcels`, cache first, in parallel. A person's
/// own queue is a handful of tasks, and each read is the one a task's map
/// already makes. Asked of backend 1 (2026-10-29): the ids on the queue's
/// rows, which would make this one read; `parcelsByTask` is the seam either
/// source fills.
@MainActor
@Observable
final class TaskParcelCounts {
    /// Each task's parcel ids, as far as they have been read.
    private(set) var parcelsByTask: [String: [String]] = [:]

    typealias Load = @MainActor (String, @escaping @MainActor @Sendable (LoadState<[Parcel]>) -> Void) async -> Void
    private let loadParcels: Load

    init(load: @escaping Load = { id, publish in
        await CachedResource.loadShowingCacheFirst(WorkItemAPI.parcelsPath(id)) {
            try await WorkItemAPI.decodeParcels(from: $0)
        } publish: { publish($0) }
    }) {
        loadParcels = load
    }

    /// Reads the parcels of these tasks, and forgets any task no longer
    /// among them: a task closed since is no longer counted.
    func load(_ taskIDs: [String]) async {
        let wanted = Set(taskIDs)
        parcelsByTask = parcelsByTask.filter { wanted.contains($0.key) }
        await withDiscardingTaskGroup { group in
            for id in wanted {
                group.addTask { await self.loadOne(id) }
            }
        }
    }

    private func loadOne(_ taskID: String) async {
        await loadParcels(taskID) { [weak self] answer in
            // A task whose parcels cannot be read counts nowhere rather than
            // somewhere wrong; the list under the map still shows it.
            if case .loaded(let parcels, _) = answer {
                self?.parcelsByTask[taskID] = parcels.map(\.id)
            }
        }
    }

    /// By parcel id: how many tasks touch it. A task naming one parcel
    /// twice counts once.
    var counts: [String: Int] { Self.counts(parcelsByTask) }

    nonisolated static func counts(_ byTask: [String: [String]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for parcels in byTask.values {
            for parcel in Set(parcels) { counts[parcel, default: 0] += 1 }
        }
        return counts
    }
}
