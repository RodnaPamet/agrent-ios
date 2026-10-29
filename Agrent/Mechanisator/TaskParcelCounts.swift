import Foundation
import Observation

/// How many of the mechanisator's current tasks touch each parcel: the
/// numbers on the whole-farm map (#465).
///
/// ── From the queue's rows, else one read per task ──
///
/// Since agri-saas #2476 each row of the person's queue carries its
/// `parcelIds`, so the numbers cost no request of their own. A row without
/// them (a queue cached before the field) has its parcels read from
/// `GET /tasks/{id}/parcels`, cache first, in parallel, as before: the read
/// a task's map already makes. `parcelsByTask` is the seam both fill.
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

    /// The parcels of these tasks: a row's own `parcelIds` where it has
    /// them, a read where it doesn't.
    func load(_ tasks: [WorkItemSummary]) async {
        let known = Dictionary(tasks.compactMap { task in task.parcelIds.map { (task.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        await load(tasks.map(\.id), known: known)
    }

    /// Reads the parcels of these tasks, takes `known` as given, and forgets
    /// any task no longer among them: a task closed since stops counting.
    func load(_ taskIDs: [String], known: [String: [String]] = [:]) async {
        let wanted = Set(taskIDs)
        parcelsByTask = parcelsByTask.filter { wanted.contains($0.key) }
        parcelsByTask.merge(known.filter { wanted.contains($0.key) }) { _, given in given }
        await withDiscardingTaskGroup { group in
            for id in wanted where known[id] == nil {
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
