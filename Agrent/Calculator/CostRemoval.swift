import Foundation
import Observation

/// A «Разходи» row swiped away (#481, owner 2026-10-31): «Изтрий», then
/// «Сигурни ли сте, че искате да изтриете разхода?», then five seconds of
/// «Отмени» before anything is sent — Задачи's and Дневник's rules
/// (`TaskRemoval`), for an expense.
///
/// ── Hidden at once, sent after the window ──
///
/// The row leaves the list when the question is answered, and the bar under
/// the list names it, with «Отмени». Only once the window closes does the
/// delete go, so «Отмени» leaves nothing behind, and an app closed inside
/// the window sends nothing.
///
/// ── What the server does with it ──
///
/// `DELETE /grain/costs/{id}` is a soft delete for anyone who may write,
/// answering `{ id }`. Nothing on either client undeletes one, so the window
/// is the only way back, which is why it is longer under assistive
/// technology. Once it is taken, the calculator reads again: an expense is a
/// term in every figure on the screen above it.
///
/// A 404 counts as done: the expense is already gone, from the web or
/// another phone.
@MainActor
@Observable
final class CostRemoval {
    /// What the bar names, and what «Отмени» takes back.
    struct Undoable: Equatable, Sendable {
        let id: String
        let label: String
    }

    private enum Stage: Equatable { case waiting, sent }

    private var stages: [String: Stage] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private(set) var undoable: Undoable?
    private(set) var failure: String?
    /// The refusal alert's own switch (`costRemoval`).
    var showsFailure = false
    /// Bumped by each delete the server took, so the screen reads again.
    private(set) var deletions = 0

    private let window: Duration
    private let send: @MainActor (String) async throws -> Void

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor (String) async throws -> Void = { try await CostsAPI.delete($0) }) {
        self.window = window
        self.send = send
    }

    var hidden: Set<String> { Set(stages.keys) }

    /// The rows the list shows: the server's, less what was swiped away.
    func visible(_ items: [CostEntry]) -> [CostEntry] {
        let gone = hidden
        return gone.isEmpty ? items : items.filter { !gone.contains($0.id) }
    }

    /// The confirmed «Изтрий». A second one inside the window sends the
    /// first at once: the bar names one expense, and its «Отмени» must not
    /// undo another.
    func remove(_ cost: CostEntry, window override: Duration? = nil) {
        guard stages[cost.id] == nil else { return }
        if let earlier = undoable { sendNow(earlier.id) }
        failure = nil
        showsFailure = false
        stages[cost.id] = .waiting
        undoable = Undoable(id: cost.id, label: Self.label(cost))
        let window = override ?? window
        timers[cost.id] = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(cost.id)
        }
    }

    /// «Отмени»: back in the list, and nothing was sent.
    func undo() {
        guard let id = undoable?.id, stages[id] == .waiting else { return }
        timers.removeValue(forKey: id)?.cancel()
        stages[id] = nil
        undoable = nil
    }

    func dismissFailure() {
        failure = nil
        showsFailure = false
    }

    /// A fresh read answered: what was sent is gone from it, or the server
    /// still has it, so the list's own answer stands.
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
        } catch let error where CostsAPI.isGone(error) {
            // Already gone.
        } catch {
            stages[id] = nil
            failure = UserMessage.text(for: error)
            showsFailure = true
            return
        }
        deletions += 1
    }

    /// Offered to a person who may write: the route's own rule, and the
    /// list carries no per-row answer to read instead.
    nonisolated static func offered(to me: CurrentUser?) -> Bool {
        me?.mayWrite ?? false
    }

    static let confirmTitle = "Сигурни ли сте, че искате да изтриете разхода?"

    /// The expense as the bar and the question name it: its kind, amount
    /// and day, which is how the row reads.
    nonisolated static func label(_ cost: CostEntry) -> String {
        "\(cost.category.label), \(cost.amountText) \(cost.currency), \(BgDate.dayMonth(cost.incurredOn))"
    }

    nonisolated static func removedText(_ undoable: Undoable) -> String {
        "Изтрит разход: \(undoable.label)"
    }

    nonisolated static func announcement(_ undoable: Undoable) -> String {
        "\(removedText(undoable)). Може да се върне само с «Отмени», докато лентата е на екрана."
    }
}
