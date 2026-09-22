import Foundation
import Observation

@Observable
@MainActor
final class TasksStore {
    private(set) var state: LoadState<WorkItemPage> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(WorkItemAPI.listPath) { data in
            try await WorkItemAPI.decodeList(from: data)
        }
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

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(WorkItemAPI.detailPath(id)) { data in
            try await WorkItemAPI.decodeDetail(from: data)
        }
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
            await load()
        } catch {
            // Stay on the screen with the error visible. Closing a form
            // after a refused write is the defect filed against the web app
            // as #921 — it reads as success and the operator's work is gone.
            writeError = UserMessage.text(for: error)
        }
    }
}
