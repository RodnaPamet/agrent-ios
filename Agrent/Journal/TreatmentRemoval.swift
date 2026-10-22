import Foundation
import Observation

/// A Дневник row swiped away (#395, owner 2026-10-22): the WHOLE treatment,
/// with five seconds to take it back before anything is sent.
///
/// ── Hidden at once, sent after the window ──
///
/// The row leaves the list the moment it is swiped, and the bar under the
/// list says what went, with «Отмени». Only once the window closes does the
/// delete go to the server. So «Отмени» needs no signal and leaves nothing
/// behind: no audit event, no restore. «Кошче» is the way back afterwards,
/// for as long as the server keeps the treatment.
///
/// A second swipe inside the window sends the first one at once. The bar
/// names one treatment, and an «Отмени» that silently stood for an earlier
/// one would undo the wrong record.
///
/// ── What a refusal does ──
///
/// The row comes back, and the server's sentence says why (not its
/// creator, recorded by several people, no signal). `mayDelete` makes the
/// first two rare, since the swipe is offered only where the server said
/// yes, but the route checks again and so does this. A 404 on the route's own
/// code is counted as done: nothing is left under the handle, which is how
/// the server answers a treatment already removed from the web.
///
/// ── The phone's own copy goes with it ──
///
/// A treatment still in the outbox under the same handle is dropped, as
/// `TreatmentAbandon` drops it. The server releases an unfinished
/// treatment's key when it is removed, so a resend would record it again
/// under the same handle, as new.
///
/// ── Hidden until the list is read again ──
///
/// After the delete the list is read again (`JournalChanges`). A cached page
/// can still hold the row, so a sent handle stays hidden until the next
/// FRESH read, which no longer lists it. If that read does list it, it was
/// restored meanwhile from «Кошче» or the web, and it is shown again.
///
/// The app closed inside the window sends nothing: the treatment is still on
/// the server and in the list on the next launch, which errs on the side of
/// the record.
@MainActor
@Observable
final class TreatmentRemoval {
    /// What the bar names, and what «Отмени» takes back.
    struct Undoable: Equatable, Sendable {
        let handle: String
        let title: String
    }

    private enum Stage: Equatable {
        /// Inside the window: «Отмени» still brings it back.
        case waiting
        /// Sent and accepted. Hidden until a fresh read says otherwise.
        case sent
    }

    private var stages: [String: Stage] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    private(set) var undoable: Undoable?
    /// The last refusal, shown until dismissed or the next swipe.
    private(set) var failure: String?

    /// Five seconds, as on the web.
    static let window: Duration = .seconds(5)

    /// Under VoiceOver or Switch Control. From the swiped row to «Отмени»
    /// is several moves, and five seconds is gone before the bar is reached.
    /// The announcement says what went and that «Кошче» has it, which holds
    /// after any window.
    static let assistedWindow: Duration = .seconds(20)

    private let window: Duration
    private let send: @MainActor (String) async throws -> Void
    private let forget: @MainActor (String) async -> Void
    private let changed: @MainActor () -> Void

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor (String) async throws -> Void = { try await TreatmentAPI.abandon($0) },
         forget: @escaping @MainActor (String) async -> Void = { await OutboxStore.shared.forget($0) },
         changed: @escaping @MainActor () -> Void = { JournalChanges.shared.changed() }) {
        self.window = window
        self.send = send
        self.forget = forget
        self.changed = changed
    }

    /// The handles the list leaves out.
    var hidden: Set<String> { Set(stages.keys) }

    func isHidden(_ entry: LogEntry) -> Bool {
        entry.treatment?.treatmentGroupId.map { stages[$0] != nil } ?? false
    }

    /// The swipe. Nothing for a row that is no treatment, or is already going.
    /// `window` overrides the store's, for a person using assistive technology.
    func remove(_ entry: LogEntry, window override: Duration? = nil) {
        guard let handle = entry.treatment?.treatmentGroupId, stages[handle] == nil else { return }
        if let earlier = undoable { sendNow(earlier.handle) }
        failure = nil
        stages[handle] = .waiting
        undoable = Undoable(handle: handle, title: entry.displayTitle)
        let window = override ?? window
        timers[handle] = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(handle)
        }
    }

    /// «Отмени»: back in the list, and nothing was sent.
    func undo() {
        guard let handle = undoable?.handle, stages[handle] == .waiting else { return }
        timers.removeValue(forKey: handle)?.cancel()
        stages[handle] = nil
        undoable = nil
    }

    func dismissFailure() { failure = nil }

    /// A fresh read of the list answered. Whatever was sent is either gone
    /// from it or was put back meanwhile, so the list's own answer stands.
    func listRead() {
        stages = stages.filter { $0.value == .waiting }
    }

    /// Restored from «Кошче»: shown again on the next read.
    func restored(_ handle: String) {
        guard stages[handle] == .sent else { return }
        stages[handle] = nil
    }

    private func sendNow(_ handle: String) {
        timers.removeValue(forKey: handle)?.cancel()
        Task { await commit(handle) }
    }

    func commit(_ handle: String) async {
        guard stages[handle] == .waiting else { return }
        timers[handle] = nil
        if undoable?.handle == handle { undoable = nil }
        stages[handle] = .sent
        do {
            try await send(handle)
        } catch let error where TreatmentAPI.isNothingRecorded(error) {
            // Already gone, from the web or another phone.
        } catch {
            stages[handle] = nil
            failure = UserMessage.text(for: error)
            return
        }
        await forget(handle)
        changed()
    }

    /// Offered where the server says pressing it would succeed: the row's
    /// `mayDelete` (agri-saas #2184), for someone who may write. A row from
    /// before the field (a cached page) offers it to any writer, and the
    /// server's refusal is read out. Only a row that stands for a
    /// treatment: an entry folded to itself has no handle.
    nonisolated static func offered(_ entry: LogEntry, to me: CurrentUser?) -> Bool {
        guard let treatment = entry.treatment, treatment.isTreatment,
              treatment.treatmentGroupId != nil,
              let me, me.mayWrite else { return false }
        return treatment.mayDelete ?? true
    }

    static let actionTitle = "Изтрий"

    /// The bar's sentence: what went, by the name the row carried.
    nonisolated static func removedText(_ title: String) -> String {
        "Изтрито: \(title)"
    }

    /// What VoiceOver says at the swipe: the bar's sentence, and the way
    /// back that doesn't run out.
    nonisolated static func announcement(_ title: String) -> String {
        "\(removedText(title)). Може да бъде възстановено от «Кошче»."
    }

    static let undoTitle = "Отмени"
}
