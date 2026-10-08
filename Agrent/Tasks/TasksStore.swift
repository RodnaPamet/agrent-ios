import Foundation
import Observation

@Observable
@MainActor
final class TasksStore {
    private(set) var state: LoadState<WorkItemPage> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(WorkItemAPI.listPath) { data in
            try await WorkItemAPI.decodeList(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}

/// A task's parcels, for its map (agrent-ios#177) — every kind of task but a
/// field operation, whose map comes with its lines (`FieldOperationStore`).
/// Cached like the task beside it, so a task opened with no signal still
/// shows where it is.
@Observable
@MainActor
final class TaskParcelsStore {
    private(set) var state: LoadState<[Parcel]> = .loading
    let taskID: String

    init(taskID: String) { self.taskID = taskID }

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(WorkItemAPI.parcelsPath(taskID)) { data in
            try await WorkItemAPI.decodeParcels(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}

@Observable
@MainActor
final class TaskDetailStore {
    private(set) var state: LoadState<WorkItem> = .loading
    private let id: String

    init(id: String) { self.id = id }

    private(set) var saving = false
    private(set) var writeError: String?

    /// The outcome of the person's own status change, for the screen to
    /// play. `load()` never touches it — a refresh is not something the
    /// person did. See `WriteFeedback`.
    private(set) var writeFeedback = WriteFeedback()

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(WorkItemAPI.detailPath(id)) { data in
            try await WorkItemAPI.decodeDetail(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }

    /// Change the status, then RELOAD rather than trusting the response.
    ///
    /// The write answers in two different shapes depending on whether it
    /// changed anything — see `WorkItemAPI.setStatus`. Reloading costs a
    /// request and gets back the one shape that is modelled and verified.
    ///
    /// The key and the resolution are minted ONCE, here, and reused for
    /// every attempt at this logical change. Regenerating either between
    /// attempts turns a retry into a different request: a new key defeats
    /// the dedupe, and a re-trimmed resolution stops the server recognising
    /// the replay and earns a 400 for a no-op transition.
    func setStatus(_ status: WorkItemStatus, resolution: String?) async {
        guard !saving else { return }
        saving = true
        writeError = nil
        defer { saving = false }

        let key = UUID().uuidString
        let trimmed = resolution?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (trimmed?.isEmpty ?? true) ? nil : trimmed

        do {
            try await WorkItemAPI.setStatus(
                id, to: status, resolution: body, idempotencyKey: key
            )
            writeFeedback.saved()
            await load()
        } catch {
            // Stay on the screen with the error visible. Closing a form
            // after a refused write is the defect filed against the web app
            // as #921 — it reads as success and the operator's work is gone.
            writeError = UserMessage.text(for: error)
            writeFeedback.refused()
        }
    }
}
