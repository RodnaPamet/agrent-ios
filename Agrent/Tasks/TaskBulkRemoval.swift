import Foundation
import Observation

/// Задачи → «Още» → «Изтрий» (#625, owner 2026-11-15): tick several tasks,
/// one question, five seconds of «Отмени», then one call.
///
/// ── Who and what ──
///
/// A task can be ticked only where the row says `mayDelete == true`: this
/// person created it or is an administrator, AND it is not one block's part
/// of a recorded treatment. Stricter than the swipe, which also offers a row
/// from before the field: the bulk delete is ALL OR NOTHING (owner ruling,
/// agri-saas #2187, kept 2026-11-15), so one doubtful row would stop every
/// other one. At most 100 per call.
///
/// ── Hidden at once, sent after the window ──
///
/// The ticked tasks leave the list when the question is answered, and the
/// bar under it says how many, with «Отмени». Only once the window closes
/// does anything go, so «Отмени» leaves nothing behind and an app closed
/// inside the window sends nothing.
///
/// ── A refusal ──
///
/// Nothing was deleted, so every task comes back, still ticked, and the
/// server's count says how many of them stopped it.
///
/// ── Not for ever ──
///
/// The server soft-deletes (owner, 2026-11-15: the words must not promise
/// otherwise), so nothing here says «завинаги».
@MainActor
@Observable
final class TaskBulkRemoval {
    private enum Stage: Equatable { case idle, waiting, sending }

    /// The ticking mode is on.
    private(set) var selecting = false
    private(set) var selected: Set<String> = []
    private var stage: Stage = .idle
    private var timer: Task<Void, Never>?
    /// The ids the list leaves out: waiting out the window, or sent and not
    /// yet read again.
    private(set) var hidden: Set<String> = []
    /// How many the bar names while «Отмени» stands.
    private(set) var pendingCount = 0
    /// The question's switch.
    var asking = false
    private(set) var failure: String?
    var showsFailure = false
    /// Bumped by each batch the server took, so the list reads again.
    private(set) var batches = 0

    private let window: Duration
    private let send: @MainActor ([String]) async throws -> Int

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor ([String]) async throws -> Int = { try await WorkItemAPI.delete($0) }) {
        self.window = window
        self.send = send
    }

    var undoable: Bool { stage == .waiting }

    func start() {
        guard stage == .idle else { return }
        selected = []
        selecting = true
    }

    func cancel() {
        selected = []
        selecting = false
    }

    func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count < WorkItemAPI.bulkMaximum {
            selected.insert(id)
        }
    }

    /// Every task offered on screen, the first 100; a second tap clears them.
    func selectAll(_ ids: [String]) {
        let wanted = Set(ids.prefix(WorkItemAPI.bulkMaximum))
        selected = wanted.isSubset(of: selected) ? [] : wanted
    }

    func allSelected(_ ids: [String]) -> Bool {
        !ids.isEmpty && Set(ids.prefix(WorkItemAPI.bulkMaximum)).isSubset(of: selected)
    }

    /// Tickable: the row says yes, in so many words (see the header).
    nonisolated static func offered(_ item: WorkItemSummary, to me: CurrentUser?) -> Bool {
        guard let me, me.mayWrite else { return false }
        return item.mayDelete == true
    }

    /// «Изтрий (N)»: the question.
    func ask() {
        guard !selected.isEmpty, stage == .idle else { return }
        asking = true
    }

    /// The confirmed question: hidden at once, sent after the window.
    func confirm(window override: Duration? = nil) {
        guard !selected.isEmpty, stage == .idle else { return }
        failure = nil
        showsFailure = false
        hidden = selected
        pendingCount = selected.count
        selecting = false
        stage = .waiting
        let window = override ?? window
        timer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit()
        }
    }

    /// «Отмени»: every task back, nothing sent, and the ticks kept so the
    /// person can change them.
    func undo() {
        guard stage == .waiting else { return }
        timer?.cancel()
        timer = nil
        hidden = []
        stage = .idle
        selecting = true
    }

    func dismissFailure() {
        failure = nil
        showsFailure = false
    }

    /// A fresh read answered: the list's own answer stands.
    func listRead() {
        guard stage == .idle else { return }
        hidden = []
    }

    func commit() async {
        guard stage == .waiting else { return }
        timer = nil
        stage = .sending
        let ids = Array(hidden).sorted()
        do {
            _ = try await send(ids)
            selected = []
            stage = .idle
            batches += 1
        } catch {
            // All or nothing: every one is still there, still ticked.
            hidden = []
            stage = .idle
            selecting = true
            failure = UserMessage.text(for: error)
            showsFailure = true
        }
    }

    nonisolated static let actionTitle = "Изтрий"
    nonisolated static let selectAllTitle = "Избери всички"
    nonisolated static let clearAllTitle = "Махни избора"

    nonisolated static func deleteButton(_ count: Int) -> String {
        count == 0 ? actionTitle : "\(actionTitle) (\(count))"
    }

    nonisolated static func confirmTitle(_ count: Int) -> String {
        count == 1 ? "Да се изтрие ли 1 задача?" : "Да се изтрият ли \(count) задачи?"
    }

    nonisolated static let confirmMessage = "До 5 секунди след това можете да ги върнете с «Отмени»."

    nonisolated static func removedText(_ count: Int) -> String {
        "Изтрити: " + Plural.bg(count, "задача", "задачи") + "."
    }

    nonisolated static func announcement(_ count: Int) -> String {
        "\(removedText(count)) Може да ги върнете с «Отмени», докато лентата е на екрана."
    }
}
