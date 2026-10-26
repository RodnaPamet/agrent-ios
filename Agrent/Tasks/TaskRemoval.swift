import Foundation
import Observation

/// A Задачи row swiped away (#454, owner 2026-10-26): «Изтрий», then
/// «Сигурни ли сте, че искате да изтриете задачата?», then five seconds of
/// «Отмени» before anything is sent. The journal's rules (`TreatmentRemoval`),
/// for a task.
///
/// ── Hidden at once, sent after the window ──
///
/// The row leaves the list when the question is answered, and the bar under
/// the list names it, with «Отмени». Only once the window closes does the
/// delete go. So «Отмени» needs no signal and leaves nothing behind. The app
/// closed inside the window sends nothing: the task is still there on the
/// next launch, which errs on the side of the farm's work.
///
/// ── And then it is gone ──
///
/// `DELETE /tasks/{taskId}` is a hard delete: the task's comments and links
/// go with it (agri-saas #2187). The window is the only way back, which is
/// why it is longer under assistive technology.
///
/// A second confirmed delete inside the window sends the first at once: the
/// bar names one task, and an «Отмени» standing for an earlier one would
/// undo the wrong one.
///
/// ── What a refusal does ──
///
/// The row comes back, and the server's sentence says why. `mayDelete`
/// makes that rare, as the swipe is offered only where the server said yes,
/// but the route checks again and so does this. A 404 counts as done: the
/// task is already gone, from the web or another phone.
@MainActor
@Observable
final class TaskRemoval {
    /// What the bar names, and what «Отмени» takes back.
    struct Undoable: Equatable, Sendable {
        let id: String
        let title: String
    }

    private enum Stage: Equatable { case waiting, sent }

    private var stages: [String: Stage] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private(set) var undoable: Undoable?
    /// The server's sentence for a refused delete, while it is said.
    private(set) var failure: String?
    /// Bumped by each delete the server took, so the list reads again.
    private(set) var deletions = 0

    private let window: Duration
    private let send: @MainActor (String) async throws -> Void
    private let changed: @MainActor () -> Void

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor (String) async throws -> Void = { try await WorkItemAPI.delete($0) },
         changed: @escaping @MainActor () -> Void = {}) {
        self.window = window
        self.send = send
        self.changed = changed
    }

    /// The ids the list leaves out.
    var hidden: Set<String> { Set(stages.keys) }

    /// The confirmed «Изтрий». `window` overrides the store's, for a person
    /// using assistive technology.
    func remove(_ item: WorkItemSummary, window override: Duration? = nil) {
        guard stages[item.id] == nil else { return }
        if let earlier = undoable { sendNow(earlier.id) }
        failure = nil
        stages[item.id] = .waiting
        undoable = Undoable(id: item.id, title: item.title)
        let window = override ?? window
        timers[item.id] = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(item.id)
        }
    }

    /// «Отмени»: back in the list, and nothing was sent.
    func undo() {
        guard let id = undoable?.id, stages[id] == .waiting else { return }
        timers.removeValue(forKey: id)?.cancel()
        stages[id] = nil
        undoable = nil
    }

    func dismissFailure() { failure = nil }

    /// A fresh read of the list answered: whatever was sent is gone from it,
    /// or the server still has it, so the list's own answer stands.
    func listRead() {
        stages = stages.filter { $0.value == .waiting }
    }

    private func sendNow(_ id: String) {
        timers.removeValue(forKey: id)?.cancel()
        Task { await commit(id) }
    }

    func commit(_ id: String) async {
        guard stages[id] == .waiting else { return }
        timers[id] = nil
        if undoable?.id == id { undoable = nil }
        stages[id] = .sent
        do {
            try await send(id)
        } catch let error where WorkItemAPI.isGone(error) {
            // Already gone.
        } catch {
            stages[id] = nil
            failure = UserMessage.text(for: error)
            return
        }
        deletions += 1
        changed()
    }

    /// Offered where the server says pressing it would succeed: the row's
    /// `mayDelete` (agri-saas #2396). Read as `== false` hides it, never
    /// `!= true`: a row from before the field (a cached page) offers it to
    /// anyone who may write, and the route's refusal is read out. A stale
    /// "no" would cost a farmer their own task; a stale "yes" costs one
    /// refusal (backend 1, 2026-10-26).
    nonisolated static func offered(_ item: WorkItemSummary, to me: CurrentUser?) -> Bool {
        guard let me, me.mayWrite else { return false }
        return item.mayDelete != false
    }

    static let confirmTitle = "Сигурни ли сте, че искате да изтриете задачата?"

    /// The bar's sentence: what went, by its title.
    nonisolated static func removedText(_ undoable: Undoable) -> String {
        "Изтрита: \(undoable.title)"
    }

    /// What VoiceOver says once it goes: the bar's sentence, and that the
    /// way back is «Отмени» and nothing else.
    nonisolated static func announcement(_ undoable: Undoable) -> String {
        "\(removedText(undoable)). Може да се върне само с «Отмени», докато лентата е на екрана."
    }
}
