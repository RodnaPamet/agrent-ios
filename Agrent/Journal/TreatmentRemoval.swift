import Foundation
import Observation

/// A Дневник row swiped away (#395, owner 2026-10-22): the WHOLE treatment,
/// with five seconds to take it back before anything is sent.
///
/// ── Manual entries too ──
///
/// Owner, 2026-11-02: "add a swipe to delete for manual entries after all",
/// over sample and test entries that had no way out. A row that stands for
/// a treatment or an activity goes whole, by its handle; an ordinary manual
/// entry (`parcelCount` 0, the server's own discriminator) goes by its id,
/// `DELETE /journal/{id}`. Both are erased, and both get the same question
/// and the same five seconds. `Self.key` is the one place that tells them
/// apart, and an entry's key carries `entryPrefix`, so the two can never be
/// mistaken for each other in the stages or in what is sent.
///
/// ── Hidden at once, sent after the window ──
///
/// The row leaves the list the moment it is swiped, and the bar under the
/// list says what went, with «Отмени». Only once the window closes does the
/// delete go to the server. So «Отмени» needs no signal and leaves nothing
/// behind: no audit event, no restore.
///
/// ── And then it is gone ──
///
/// There is no way back after the window (owner, 2026-10-24: "what's deleted
/// is deleted"). «Кошче» and its restore were removed (#411), and the server
/// erases the treatment rather than hiding it. So the window is the only
/// second chance, which is why it is longer under assistive technology.
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
/// FRESH read, which no longer lists it. If that read does list it, the
/// server still has it, and the list's answer is shown rather than the
/// phone's belief.
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
        /// How much one swipe removed: «3 парцела в 2 блока». A row reads as
        /// one line and can stand for a dozen parcels across blocks, which
        /// the web's toast names for the same reason (agri-saas #2192). Nil
        /// when the row says neither.
        var extent: String? = nil
    }

    /// «3 парцела в 2 блока», «1 парцел», or nil when the row counts nothing.
    /// Each number is held to its noun with a no-break space, so a narrow
    /// bar never leaves «3» alone at the end of a line.
    nonisolated static func extent(of treatment: JournalTreatment?) -> String? {
        guard let treatment, treatment.parcelCount > 0 else { return nil }
        let parcels = held(Plural.bg(treatment.parcelCount, "парцел", "парцела"))
        guard !treatment.blockNames.isEmpty else { return parcels }
        return "\(parcels) в \(held(Plural.bg(treatment.blockNames.count, "блок", "блока")))"
    }

    private nonisolated static func held(_ counted: String) -> String {
        counted.replacingOccurrences(of: " ", with: "\u{00A0}")
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
    /// is several moves, and five seconds is gone before the bar is reached —
    /// and with no «Кошче» (#411), missing it means the record is gone.
    static let assistedWindow: Duration = .seconds(20)

    private let window: Duration
    private let send: @MainActor (String) async throws -> Void
    private let forget: @MainActor (String) async -> Void
    private let changed: @MainActor () -> Void

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor (String) async throws -> Void = { try await TreatmentRemoval.sendDelete($0) },
         forget: @escaping @MainActor (String) async -> Void = { await OutboxStore.shared.forget($0) },
         changed: @escaping @MainActor () -> Void = { JournalChanges.shared.changed() }) {
        self.window = window
        self.send = send
        self.forget = forget
        self.changed = changed
    }

    /// The keys the list leaves out.
    var hidden: Set<String> { Set(stages.keys) }

    func isHidden(_ entry: LogEntry) -> Bool {
        Self.key(entry).map { stages[$0] != nil } ?? false
    }

    /// What a row is removed BY: its treatment's handle when it stands for
    /// one, `entry:<id>` when it is an ordinary manual entry, nil when the
    /// row cannot say. A read that does not fold sends no `treatment`, and
    /// there an entry may be one parcel's row of a treatment: removed alone,
    /// it would leave the treatment short a parcel.
    nonisolated static func key(_ entry: LogEntry) -> String? {
        guard let treatment = entry.treatment else { return nil }
        if treatment.isTreatment { return treatment.treatmentGroupId }
        guard treatment.pendingCount == 0, treatment.lineCount == 0 else { return nil }
        return entryPrefix + entry.id
    }

    nonisolated static let entryPrefix = "entry:"

    /// The entry id inside a manual entry's key, nil for a treatment's handle.
    nonisolated static func entryID(_ key: String) -> String? {
        key.hasPrefix(entryPrefix) ? String(key.dropFirst(entryPrefix.count)) : nil
    }

    /// The server's delete for either kind of key.
    static func sendDelete(_ key: String) async throws {
        if let id = entryID(key) {
            try await JournalAPI.deleteEntry(id)
        } else {
            try await TreatmentAPI.abandon(key)
        }
    }

    /// The swipe. Nothing for a row that cannot be removed, or is already
    /// going. `window` overrides the store's, for a person using assistive
    /// technology.
    func remove(_ entry: LogEntry, window override: Duration? = nil) {
        guard let handle = Self.key(entry), stages[handle] == nil else { return }
        if let earlier = undoable { sendNow(earlier.handle) }
        failure = nil
        stages[handle] = .waiting
        undoable = Undoable(handle: handle, title: entry.displayTitle, extent: Self.extent(of: entry.treatment))
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

    /// A fresh read of the list answered. Whatever was sent is gone from it,
    /// or the server still has it, so the list's own answer stands.
    func listRead() {
        stages = stages.filter { $0.value == .waiting }
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
        } catch let error where TreatmentAPI.isNothingRecorded(error) || JournalAPI.isGone(error) {
            // Already gone, from the web or another phone.
        } catch {
            stages[handle] = nil
            failure = UserMessage.text(for: error)
            return
        }
        // Only a treatment can be waiting in the outbox under its key.
        if Self.entryID(handle) == nil { await forget(handle) }
        changed()
    }

    /// Offered to someone who may write, where the server would take it.
    ///
    /// A treatment or an activity: the row's `mayDelete` (agri-saas #2184),
    /// and a row from before the field (a cached page) offers it to any
    /// writer, the server's refusal read out. Any work on parcels, a bare
    /// activity included: the same route withdraws pruning or a harvest as
    /// it does a spraying (agri-saas, proven by its test 2026-10-25).
    ///
    /// A manual entry: any writer, the entry route's own rule. Its
    /// `mayDelete` is false by definition ("no treatment to withdraw") and
    /// is not read.
    nonisolated static func offered(_ entry: LogEntry, to me: CurrentUser?) -> Bool {
        guard let key = key(entry), let me, me.mayWrite else { return false }
        if entryID(key) != nil { return true }
        return entry.treatment?.mayDelete ?? true
    }

    static let actionTitle = "Изтрий"

    /// Asked before anything goes (owner, 2026-10-26): «Изтрий» on the swipe
    /// opens this, and only its own «Изтрий» hides the row and starts the
    /// five seconds, so a mistaken swipe costs nothing and «Отмени» still
    /// follows a mistaken confirmation.
    static let confirmTitle = "Сигурни ли сте, че искате да изтриете записа?"

    /// Under the question: which record, and how much of the register it
    /// stands for, as the bar will say.
    nonisolated static func confirmMessage(_ entry: LogEntry) -> String {
        guard let extent = extent(of: entry.treatment) else { return entry.displayTitle }
        return "\(entry.displayTitle), \(extent)"
    }

    /// The bar's sentence: what went, by the name the row carried, and how
    /// much of the register that was.
    nonisolated static func removedText(_ undoable: Undoable) -> String {
        guard let extent = undoable.extent else { return "Изтрито: \(undoable.title)" }
        return "Изтрито: \(undoable.title), \(extent)"
    }

    /// What VoiceOver says at the swipe: the bar's sentence, and that the
    /// way back is «Отмени» and nothing else — there is no «Кошче» (#411).
    nonisolated static func announcement(_ undoable: Undoable) -> String {
        "\(removedText(undoable)). Може да се върне само с «Отмени», докато лентата е на екрана."
    }

    static let undoTitle = "Отмени"
}
