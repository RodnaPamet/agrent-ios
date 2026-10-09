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

    /// A comment being sent (#225), and what the last send came to.
    private(set) var commenting = false
    private(set) var commentError: String?

    /// The key for the comment being sent, kept while its text is the same —
    /// see `WorkItemAPI.addComment`. A different text is a different comment.
    @ObservationIgnored private var commentKey: (text: String, key: String)?

    /// Send a comment, then re-read the task, which carries its comments.
    /// True when it landed: the screen clears its draft only then, so a
    /// refused comment is still there to send again.
    ///
    /// Retried a couple of times on a failure worth retrying, with the SAME
    /// key (`IdempotentRetry`): since agri-saas #1441 a replay of a comment
    /// that already landed answers with that comment, so a lost answer can
    /// no longer post it twice.
    func addComment(_ text: String) async -> Bool {
        guard !commenting else { return false }
        commenting = true
        commentError = nil
        defer { commenting = false }

        let key = commentKey.flatMap { $0.text == text ? $0.key : nil } ?? UUID().uuidString
        commentKey = (text, key)
        do {
            try await IdempotentRetry.run {
                try await WorkItemAPI.addComment(id, text: text, idempotencyKey: key)
            }
            commentKey = nil
            writeFeedback.saved()
            await load()
            return true
        } catch {
            commentError = UserMessage.text(for: error)
            writeFeedback.refused()
            return false
        }
    }

    /// What closing came to (#226).
    enum CloseOutcome: Equatable {
        case closed
        /// Closed, with the weeds in its note — but `parcels` of the task's
        /// parcels did not take the observation, for `reason`.
        case closedWithoutWeeds(parcels: Int, reason: String)
        /// Not closed. The form stays open with its answers: closing a form
        /// after a refused write is the web's defect #921 — it reads as
        /// success, and the operator's answers are gone.
        case refused(String)
    }

    /// Said under the task when a close landed and its weeds did not.
    private(set) var closeNotice: String?

    /// The key for the close being sent, kept while its note is the same,
    /// so a second tap on «Завърши» after a lost answer is the same request
    /// — which the status route recognises as already applied.
    @ObservationIgnored private var closeKey: (resolution: String, key: String)?

    /// Close the task with the form's answers, then record its weeds.
    ///
    /// CLOSE FIRST. The close is the one thing the form exists for, so it is
    /// never held behind the weeds. Then one observation per parcel, all with
    /// the same moment, each retried a couple of times with its own key
    /// (`IdempotentRetry`; the route replays since agri-saas #1441). One that
    /// is still refused leaves the close standing — the weeds are in the
    /// note either way — and is said under the task.
    ///
    /// Then RELOAD rather than trusting the response: the status route
    /// answers in two shapes depending on whether it changed anything.
    func close(resolution: String, weeds: [String], parcelIDs: [String], note: String) async -> CloseOutcome {
        guard !saving else { return .refused(TaskCloseText.inProgress) }
        saving = true
        closeNotice = nil
        defer { saving = false }

        let key = closeKey.flatMap { $0.resolution == resolution ? $0.key : nil } ?? UUID().uuidString
        closeKey = (resolution, key)
        do {
            try await WorkItemAPI.setStatus(id, to: .closed, resolution: resolution, idempotencyKey: key)
        } catch {
            writeFeedback.refused()
            return .refused(UserMessage.text(for: error))
        }
        closeKey = nil
        writeFeedback.saved()

        var failed = 0
        var reason: String?
        if !weeds.isEmpty {
            let observedAt = Date()
            for parcelID in parcelIDs {
                // One key per parcel per close, kept across its retries —
                // and never shared between parcels: the server scopes the
                // replay to the parcel, so a shared key is an error there.
                let key = UUID().uuidString
                do {
                    try await IdempotentRetry.run {
                        try await WorkItemAPI.recordWeeds(
                            taskID: id, parcelID: parcelID, observedAt: observedAt, weeds: weeds,
                            notes: note, idempotencyKey: key)
                    }
                } catch {
                    failed += 1
                    reason = reason ?? UserMessage.text(for: error)
                }
            }
        }
        await load()
        guard failed > 0, let reason else { return .closed }
        closeNotice = TaskCloseText.weedsNotRecorded(parcels: failed, reason: reason)
        return .closedWithoutWeeds(parcels: failed, reason: reason)
    }
}
