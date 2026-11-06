import Foundation
import Observation

/// A РЕКОЛТИ or ПЛЕВЕЛИ row swiped away (owner, 2026-11-06, #541: "yes"):
/// «Изтрий», then «Сигурни ли сте…?», then five seconds of «Отмени» before
/// anything is sent — the app's rules for every delete (`CostRemoval`,
/// `TaskRemoval`), for a parcel's crop season or weed observation.
///
/// ── Hidden at once, sent after the window ──
///
/// The row leaves the list when the question is answered, and the bar under
/// the list names it, with «Отмени». Only once the window closes does the
/// delete go, so «Отмени» leaves nothing behind.
///
/// ── What the server does with it ──
///
/// `DELETE …/crop-seasons/{id}` and `…/weed-observations/{id}` are soft
/// deletes for anyone who may write; the web's words for it are «Записът
/// няма да се показва повече в архива.». Nothing undeletes one, so the window
/// is the only way back. Then the archive reads again, so the section's card
/// and count agree with the list.
///
/// A 404 counts as done (`ParcelHistoryAPI.deleteTreatingMissingAsDone`).
///
/// ДЕЙНОСТИ has no swipe: an operation is a completed task's line, deleted
/// with its task, not here.
@MainActor
@Observable
final class HistoryRemoval {
    enum Kind: Sendable, Equatable { case season, weeds }

    /// What a row stands for, and what the bar and the question name.
    struct Target: Equatable, Sendable, Identifiable {
        let kind: Kind
        let id: String
        let label: String
    }

    private enum Stage: Equatable { case waiting, sent }

    private var stages: [String: Stage] = [:]
    private var targets: [String: Target] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private(set) var undoable: Target?
    private(set) var failure: String?
    /// The refusal alert's own switch (`historyRemoval`).
    var showsFailure = false
    /// Bumped by each delete the server took, so the archive reads again.
    private(set) var deletions = 0

    private let window: Duration
    private let send: @MainActor (Target) async throws -> Void

    init(parcelID: String, window: Duration = TreatmentRemoval.window,
         send: (@MainActor (Target) async throws -> Void)? = nil) {
        self.window = window
        self.send = send ?? { target in
            switch target.kind {
            case .season:
                try await ParcelHistoryAPI.deleteCropSeason(parcelID: parcelID, seasonID: target.id)
            case .weeds:
                try await ParcelHistoryAPI.deleteWeedObservation(parcelID: parcelID, observationID: target.id)
            }
        }
    }

    /// Whether a row is out of the list: swiped, waiting, or sent and not
    /// yet read back.
    func isHidden(_ id: String) -> Bool { stages[id] != nil }

    /// The confirmed «Изтрий». A second one inside the window sends the
    /// first at once: the bar names one entry, and its «Отмени» must not
    /// undo another.
    func remove(_ target: Target, window override: Duration? = nil) {
        guard stages[target.id] == nil else { return }
        if let earlier = undoable { sendNow(earlier.id) }
        failure = nil
        showsFailure = false
        stages[target.id] = .waiting
        targets[target.id] = target
        undoable = target
        let window = override ?? window
        timers[target.id] = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(target.id)
        }
    }

    /// «Отмени»: back in the list, and nothing was sent.
    func undo() {
        guard let id = undoable?.id, stages[id] == .waiting else { return }
        timers.removeValue(forKey: id)?.cancel()
        stages[id] = nil
        targets[id] = nil
        undoable = nil
    }

    func dismissFailure() {
        failure = nil
        showsFailure = false
    }

    /// A fresh read answered: what was sent is gone from it, or the server
    /// still has it, so the archive's own answer stands.
    func archiveRead() {
        stages = stages.filter { $0.value == .waiting }
        targets = targets.filter { stages[$0.key] != nil }
    }

    private func sendNow(_ id: String) {
        timers.removeValue(forKey: id)?.cancel()
        Task { await commit(id) }
    }

    func commit(_ id: String) async {
        guard stages[id] == .waiting, let target = targets[id] else { return }
        timers[id] = nil
        if undoable?.id == id { undoable = nil }
        stages[id] = .sent
        do {
            try await send(target)
        } catch {
            stages[id] = nil
            targets[id] = nil
            failure = UserMessage.text(for: error)
            showsFailure = true
            return
        }
        deletions += 1
    }

    /// Offered to a person who may write: the routes' own rule
    /// (`assertCanWrite`), and the archive carries no per-row answer.
    nonisolated static func offered(to me: CurrentUser?) -> Bool {
        me?.mayWrite ?? false
    }

    nonisolated static func confirmTitle(_ kind: Kind) -> String {
        switch kind {
        case .season: "Сигурни ли сте, че искате да изтриете културата?"
        case .weeds: "Сигурни ли сте, че искате да изтриете наблюдението?"
        }
    }

    /// Under the question: what it is, and the web's sentence for what
    /// happens to it.
    nonisolated static func confirmMessage(_ target: Target) -> String {
        "\(target.label). Записът няма да се показва повече в архива."
    }

    nonisolated static func removedText(_ target: Target) -> String {
        switch target.kind {
        case .season: "Изтрита култура: \(target.label)"
        case .weeds: "Изтрито наблюдение: \(target.label)"
        }
    }

    nonisolated static func announcement(_ target: Target) -> String {
        "\(removedText(target)). Може да се върне само с «Отмени», докато лентата е на екрана."
    }

    static let failureTitle = "Записът не е изтрит"
}

extension HistoryRemoval.Target {
    /// A season as its row reads: «2026, Пшеница».
    init(_ season: CropSeason) {
        self.init(kind: .season, id: season.id, label: Self.clause(season.historyLine))
    }

    /// An observation as its row reads: «2 април, Балур (Sorghum halepense)».
    init(_ observation: WeedObservation) {
        self.init(kind: .weeds, id: observation.id, label: Self.clause(observation.historyLine))
    }

    /// The row's spoken form without its full stop: it sits inside the
    /// question's sentence and after «Изтрита култура:».
    private static func clause(_ line: ParcelHistoryLine) -> String {
        var text = line.spoken
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
