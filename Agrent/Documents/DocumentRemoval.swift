import Foundation
import Observation

/// A document swiped away (#468): «Изтрий», «Сигурни ли сте…», then five
/// seconds of «Отмени» before anything is sent, as on Задачи and Дневник
/// (`TaskRemoval`, whose rules these are).
///
/// ── What the server does with it ──
///
/// `DELETE /documents/{id}` deletes the bytes and keeps the row as a
/// tombstone without its name, «Изтрит на … от …» (owner, 2026-10-30). The
/// Drive copy, if any, stays. So the window is the only way to keep the file
/// on Agrent, which is why it is longer under assistive technology. Until
/// the window closes the row is simply hidden; afterwards the list is read
/// again and shows the tombstone.
@MainActor
@Observable
final class DocumentRemoval {
    struct Undoable: Equatable, Sendable {
        let id: String
        let name: String
    }

    private enum Stage: Equatable { case waiting, sent }

    private var stages: [String: Stage] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private(set) var undoable: Undoable?
    private(set) var failure: String?
    var showsFailure = false
    /// Bumped by each delete the server took, so the list reads again.
    private(set) var deletions = 0

    private let window: Duration
    private let send: @MainActor (String) async throws -> Void

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor (String) async throws -> Void = { try await DocumentsAPI.delete($0) }) {
        self.window = window
        self.send = send
    }

    var hidden: Set<String> { Set(stages.keys) }

    /// The rows a list shows: the server's, less what was swiped away.
    func visible(_ items: [FarmDocument]) -> [FarmDocument] {
        let gone = hidden
        return gone.isEmpty ? items : items.filter { !gone.contains($0.id) }
    }

    /// The confirmed «Изтрий». A second inside the window sends the first at
    /// once: the bar names one document, and its «Отмени» must not undo
    /// another.
    func remove(_ document: FarmDocument, window override: Duration? = nil) {
        guard stages[document.id] == nil else { return }
        if let earlier = undoable { sendNow(earlier.id) }
        failure = nil
        showsFailure = false
        stages[document.id] = .waiting
        undoable = Undoable(id: document.id, name: document.name ?? "Документ")
        let window = override ?? window
        timers[document.id] = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(document.id)
        }
    }

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

    /// A fresh read answered: what was sent now shows as its tombstone.
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
        } catch {
            stages[id] = nil
            failure = UserMessage.text(for: error)
            showsFailure = true
            return
        }
        deletions += 1
    }

    /// Offered where the server says pressing it would succeed, read as
    /// `== false` hides it, as tasks do. Never on a tombstone.
    nonisolated static func offered(_ document: FarmDocument, to me: CurrentUser?) -> Bool {
        guard let me, me.mayWrite, !document.isPurged else { return false }
        return document.mayDelete != false
    }

    static let confirmTitle = "Сигурни ли сте, че искате да изтриете документа?"

    /// Said under the question: the bytes go for good, the row stays.
    static let confirmMessage =
        "Файлът се изтрива от Agrent. В списъка остава ред, че е бил изтрит. Копие в Google Drive, ако има, остава."

    nonisolated static func removedText(_ undoable: Undoable) -> String {
        "Изтрит: \(undoable.name)"
    }

    nonisolated static func announcement(_ undoable: Undoable) -> String {
        "\(removedText(undoable)). Може да се върне само с «Отмени», докато лентата е на екрана."
    }
}
