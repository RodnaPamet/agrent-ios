import Foundation
import Observation

/// A field operation's parcel lines on the task screen, and the operator's
/// marks on them (agrent-ios#138, ported from the web's `FieldOperationPanel`
/// and the offline field panel's queue).
///
/// ── What a tap does ──
///
/// One request, guarded by the version the line was READ at:
///
///   landed      the row takes the server's answer at once, unsent marks for
///               the line are dropped, and the job is re-read behind it.
///   409         someone else changed the line since it was read. Said in
///               Bulgarian, re-read, and NOTHING overwritten — the operator
///               looks at the line as it is now and marks again if they still
///               mean to (#138: never silently overwrite).
///   no signal   (or a 5xx, 408, 429) the mark is QUEUED with the version it
///               saw, and replayed with that `If-Match` — so a replay over a
///               change made meanwhile meets a 409 and is parked as a
///               conflict for the operator, never sent over it.
///   refused     a 403, 400, 404: said, and not queued — a refusal will be
///               a refusal tomorrow.
///   426         this BUILD is too old for the server (#168). Said, and
///               nothing on the phone touched: not queued, not re-read, and
///               the line's unsent marks left to wait for the updated app.
///
/// ── Haptics (#155's two words) ──
///
/// `.success` when a «Готово» lands — or is kept on the phone to send, which
/// #155 counts as landed for field work, as the web does. `.warning` on a
/// refusal, a conflict or a 426. Skip and reopen play nothing: the web gives
/// them a `tap`, and this app's vocabulary has no tap. Nothing the app does
/// on its own — a reload, the drain sending a queued mark, a conflict the
/// drain parks — plays anything (`HapticSiteTests`).
@Observable
@MainActor
final class FieldOperationStore {
    let taskID: String

    /// For naming a queued mark in the outbox banner («FT-102 · SYNTH-1 ·
    /// Готово»), which floats over every tab and needs to say which task.
    let taskKey: String?

    private(set) var state: LoadState<FieldOperationDetail> = .loading

    /// The line whose mark is in flight. One at a time: the version a second
    /// tap would assert is the one the first is about to change.
    private(set) var busyLineID: String?

    /// What the last tap came to, said under its line.
    private(set) var notice: Notice?

    /// The tap's outcome, for `.writeFeedback` — see the header.
    private(set) var feedback = WriteFeedback()

    /// Bumped when a mark finished the job: the task above it has just moved
    /// to PENDING_REVIEW and should be re-read.
    private(set) var finishedJob = 0

    struct Notice: Equatable {
        enum Kind: Equatable {
            /// Kept on the phone to send — true only while it still waits
            /// (`FieldOperationRules.visibleNotice`).
            case kept
            /// A mark waiting on the phone was cancelled; nothing was sent.
            case cancelled
            /// The line changed under the tap.
            case conflict
            /// The server said no.
            case refused
        }

        let lineID: String
        let kind: Kind
        let text: String
    }

    typealias Fetch = @MainActor (
        _ taskID: String, _ showCachedFirst: Bool,
        _ publish: @escaping @MainActor @Sendable (LoadState<FieldOperationDetail>) -> Void
    ) async -> Void

    /// Seams for `FieldOperationLinesTests`: the read, the write, the body
    /// and the queue. The app uses the real four; a test drives a mark to
    /// every outcome with nothing sent.
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let send: (FieldOperationAPI.MarkRequest) async throws -> FieldOperationAPI.Landed
    @ObservationIgnored private let encode: (OperationLineStatus) async throws -> Data
    @ObservationIgnored private let outbox: OutboxStore

    init(
        taskID: String,
        taskKey: String?,
        fetch: @escaping Fetch = FieldOperationStore.fetchCacheFirst,
        send: @escaping (FieldOperationAPI.MarkRequest) async throws -> FieldOperationAPI.Landed = {
            try await FieldOperationAPI.mark($0)
        },
        encode: @escaping (OperationLineStatus) async throws -> Data = {
            try await FieldOperationAPI.body($0)
        },
        // nil-then-`.shared` in the body rather than a `= .shared` default: a
        // default argument is evaluated outside the main actor, and the
        // outbox is main-actor state (the same call as `CurrentUserStore`).
        outbox: OutboxStore? = nil
    ) {
        self.taskID = taskID
        self.taskKey = taskKey
        self.fetch = fetch
        self.send = send
        self.encode = encode
        self.outbox = outbox ?? .shared
    }

    /// The real read: cached copy first, the network behind it — so a job
    /// opened once with signal can be marked in a field with none.
    static func fetchCacheFirst(
        _ taskID: String, _ showCachedFirst: Bool,
        _ publish: @escaping @MainActor @Sendable (LoadState<FieldOperationDetail>) -> Void
    ) async {
        await CachedResource.loadShowingCacheFirst(
            FieldOperationAPI.detailPath(taskID), showCachedFirst: showCachedFirst
        ) { data in
            try await FieldOperationAPI.decodeDetail(from: data)
        } publish: { publish($0) }
    }

    /// Every read is numbered when it STARTS, because reads overlap — the
    /// screen's first load, the re-read after a tap, the outbox's, a pull —
    /// and on a slow field connection they can ANSWER in any order.
    @ObservationIgnored private var readsStarted = 0
    /// The read whose fresh answer is on screen. An older one never
    /// replaces it.
    @ObservationIgnored private var shownRead = 0
    /// Reads started before this one began before a write reached the
    /// server, so their answers may predate it.
    @ObservationIgnored private var firstCurrentRead = 0

    /// Read the job. `showCachedFirst: false` after a write: the cached copy
    /// predates it, and publishing it first would show the line flipping
    /// back for as long as the network takes.
    func load(showCachedFirst: Bool = true) async {
        if state.value == nil { state = .loading }
        readsStarted += 1
        let read = readsStarted
        await fetch(taskID, showCachedFirst) { [weak self] in self?.adopt($0, from: read) }
    }

    /// Re-read after a write reached the server — the screen's own mark, or
    /// one the drain sent or parked — and disown every read already under
    /// way: they were asked before the write and may answer with the line
    /// as it was.
    ///
    /// The race this closes, on a slow connection: the screen opens and its
    /// read goes out; the operator taps «Готово» from the cached copy; the
    /// mark lands and its re-read comes back first; then the opening read
    /// arrives, FRESH and from before the mark. Adopted, it would flip the
    /// line back and hand the next tap a version the server has left behind.
    func loadAfterWrite() async {
        disownReads()
        await load(showCachedFirst: false)
    }

    /// Called the moment a write's answer is in — before anything else is
    /// awaited, so no older read can slip in between.
    private func disownReads() {
        firstCurrentRead = readsStarted + 1
    }

    /// ONCE SOMETHING IS ON SCREEN, ONLY A NEWER FRESH ANSWER REPLACES IT.
    ///
    /// `CachedResource` falls back to the cached copy when the network fails,
    /// and publishes it as `.stale`. After a mark has LANDED that copy is
    /// older than the row on screen — the server's own answer — so adopting
    /// it would flip the line back. Every network answer writes the cache,
    /// so whatever is loaded is never older than it; and a failure must not
    /// replace lines the operator is working from with an error.
    private func adopt(_ next: LoadState<FieldOperationDetail>, from read: Int) {
        guard read >= firstCurrentRead else { return }
        guard state.value != nil else {
            state = next
            if case .loaded(_, .fresh) = next { shownRead = read }
            return
        }
        if case .loaded(_, .fresh) = next, read >= shownRead {
            state = next
            shownRead = read
        }
    }

    // MARK: - The tap

    /// Mark one line, as the person signed in.
    ///
    /// `me` is required: a mark that has to wait is stamped with its owner,
    /// so it is replayed only under their session (agri-saas#1191 P0.9). The
    /// screen does not offer the buttons until it is known.
    func mark(_ line: OperationLine, as target: OperationLineStatus, by me: CurrentUser?) async {
        guard busyLineID == nil, let me else { return }
        guard let seen = line.version else {
            // Unreachable from the screen, which offers no button for such a
            // line — see `OperationLine.version`. Said rather than sent.
            notice = Notice(lineID: line.id, kind: .refused, text: FieldOperationText.noVersion)
            return
        }
        busyLineID = line.id
        notice = nil
        defer { busyLineID = nil }

        // ── BACK TO WHAT THE SERVER HOLDS: cancel, do not send ──
        //
        // The only way to ask for the line's own server status is to undo a
        // mark still waiting on the phone («Готово» with no signal, then
        // «Отвори отново»). What the operator wants is then exactly what the
        // server already has, so the queued mark is dropped and nothing goes
        // out — not a PENDING → PENDING write that would bump the version and
        // file an audit row for nothing.
        if target == line.status {
            await outbox.supersedeMarks(taskID: taskID, lineID: line.id, keeping: nil)
            notice = Notice(lineID: line.id, kind: .cancelled, text: FieldOperationText.cancelledOnPhone)
            return
        }

        let body: Data
        do {
            body = try await encode(target)
        } catch {
            notice = Notice(lineID: line.id, kind: .refused, text: UserMessage.text(for: error))
            feedback.refused()
            return
        }
        let request = FieldOperationAPI.MarkRequest(
            taskID: taskID, lineID: line.id, body: body, seenVersion: seen)

        do {
            let landed = try await send(request)
            disownReads()
            if let detail = state.value, let freshness = state.freshness {
                state = .loaded(detail.applying(target, version: landed.version, toLine: line.id), freshness)
            }
            if target == .done { feedback.saved() }
            if landed.resolved { finishedJob += 1 }
            // Anything still waiting for this line is now older than what
            // the server holds, and would replay into a 409 against it.
            await outbox.supersedeMarks(taskID: taskID, lineID: line.id, keeping: nil)
            await load(showCachedFirst: false)
        } catch {
            switch FieldOperationRules.failure(error) {
            case .conflict:
                disownReads()
                notice = Notice(lineID: line.id, kind: .conflict, text: FieldOperationText.conflictLive)
                feedback.refused()
                await outbox.supersedeMarks(taskID: taskID, lineID: line.id, keeping: nil)
                await load(showCachedFirst: false)

            case .keep:
                // A 429 here is the outbox's 429 too: the live mark and the
                // replay draw on one budget, so the pause closes BEFORE the
                // mark joins the queue (the spray sheet's rule).
                outbox.pause.absorb(error)
                let mark = PendingOperation.LineMark(
                    taskID: taskID, lineID: line.id, status: target.rawValue, seenVersion: seen)
                await outbox.enqueueMark(.mark(
                    mark, ownerUserID: me.id,
                    summary: FieldOperationRules.summary(
                        taskKey: taskKey, parcel: line.parcel.name, status: target),
                    payload: body, reason: UserMessage.text(for: error)))
                notice = Notice(lineID: line.id, kind: .kept, text: FieldOperationText.kept)
                if target == .done { feedback.saved() }

            case .clientTooOld:
                // ── A 426 IS ABOUT THE BUILD, NOT THIS MARK (#168) ──
                //
                // The server's version gate answered before the route ran,
                // so nothing about this line was looked at — and nothing
                // about it changes here, which is where this parts from a
                // refusal. The line's unsent marks are NOT superseded: the
                // server has not seen them either, and they wait for the
                // updated app like the rest of the queue, so what the line
                // shows is still what will be sent. Nothing is queued: the
                // tap is the operator's to make again once updated, as on
                // the web, whose live mark queues nothing on a 426. (The
                // spray sheet parts from both on purpose, #169: it keeps a
                // record TYPED in a field for the updated app, and a tap
                // costs nothing to repeat.) Nothing is re-read: the read
                // would meet the same 426.
                //
                // The outbox is told, so the banner says why nothing is being
                // sent instead of offering «Изпрати» for the same answer.
                outbox.absorbClientTooOld(error)
                notice = Notice(lineID: line.id, kind: .refused, text: UserMessage.text(for: error))
                feedback.refused()

            case .refused(let message):
                disownReads()
                notice = Notice(lineID: line.id, kind: .refused, text: message)
                feedback.refused()
                await outbox.supersedeMarks(taskID: taskID, lineID: line.id, keeping: nil)
                await load(showCachedFirst: false)
            }
        }
    }
}

/// The rules, PURE — every decision the screen and the store make, testable
/// with nothing loaded and nothing sent.
enum FieldOperationRules {

    /// May this person mark the job's lines? The ROUTE's rule, for the
    /// affordance: `canWrite`, or the job's assignee without it
    /// (`markOperationParcel`: `!canWrite && !isAssignee` → 403).
    ///
    /// The house pattern (`CurrentUser.mayWrite`), so it FAILS OPEN on a role
    /// this build does not know — the role is the oldest membership's, and a
    /// hidden button is a feature the person concludes does not exist. The
    /// server's 403 is still handled: the assignment can change under an
    /// open screen.
    ///
    /// Nobody known → false, unlike the role: a mark that has to wait on the
    /// phone is stamped with its owner, and there is none to stamp.
    static func mayMark(me: CurrentUser?, assigneeUserID: String?) -> Bool {
        guard let me else { return false }
        return me.mayWrite || assigneeUserID == me.id
    }

    /// What a line may be moved to from what it SHOWS — the web's buttons:
    /// a pending line can be done or skipped, a finished one reopened.
    /// Nothing for a line in conflict (it waits for the operator's choice),
    /// for one with no version (it cannot be guarded), or for a status this
    /// build does not know.
    static func actions(for row: LineState, mayMark: Bool) -> [OperationLineStatus] {
        guard mayMark, row.conflict == nil, row.line.version != nil else { return [] }
        switch row.shown {
        case .pending: return [.done, .skipped]
        case .done, .skipped: return [.pending]
        case .unknown: return []
        }
    }

    /// Each line beside this person's queued marks for it.
    ///
    /// `pending` is the signed-in person's outbox, oldest first — so the
    /// LAST unsent mark is the newest intent, should two ever coexist.
    static func rows(lines: [OperationLine], pending: [PendingOperation], taskID: String) -> [LineState] {
        let marks = pending.filter { $0.lineMark?.taskID == taskID }
        return lines.map { line in
            let mine = marks.filter { $0.lineMark?.lineID == line.id }
            return LineState(
                line: line,
                waiting: mine.last(where: \.awaitsSend),
                conflict: mine.first { $0.conflict != nil },
                refused: mine.filter(\.isRefused)
            )
        }
    }

    /// «{done} / {total} парцела завършени», counted from what the lines
    /// SHOW — a mark still on the phone included, as the web's offline
    /// panel counts it. A skip is progress, by the spec's definition.
    static func progress(_ rows: [LineState]) -> (done: Int, total: Int) {
        (rows.filter { $0.shown.isComplete }.count, rows.count)
    }

    /// The notice a line shows: the last tap's, if it was on this line —
    /// except «запазено на телефона», which stops being true the moment the
    /// drain sends the mark or parks it, and must go with it rather than
    /// sit under a line that is now on the server.
    static func visibleNotice(_ notice: FieldOperationStore.Notice?, for row: LineState)
        -> FieldOperationStore.Notice? {
        guard let notice, notice.lineID == row.id else { return nil }
        if notice.kind == .kept, row.waiting == nil { return nil }
        return notice
    }

    /// How a queued mark is named in the banner and the conflict card.
    static func summary(taskKey: String?, parcel: String, status: OperationLineStatus) -> String {
        [taskKey, parcel, status.label]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    enum Failure: Equatable {
        case conflict(currentVersion: Int?)
        case keep
        /// A 426: this BUILD is too old for the server (#168). Neither kept
        /// nor refused — see the branch in `FieldOperationStore.mark`.
        case clientTooOld
        case refused(String)
    }

    /// What a failed live mark becomes. The 409 is checked FIRST: it is not
    /// worth retrying, and it is not a refusal either. The 426 next, for the
    /// same two reasons — the retry policy calls it final, and it says
    /// nothing about the mark — and because a refusal SUPERSEDES the line's
    /// unsent marks, which a 426 must not (#168).
    static func failure(_ error: Error) -> Failure {
        if case APIClient.APIError.conflict(let current, _) = error {
            return .conflict(currentVersion: current)
        }
        if case APIClient.APIError.clientTooOld = error { return .clientTooOld }
        if PendingOperations.isWorthRetrying(error) { return .keep }
        return .refused(UserMessage.text(for: error))
    }

    /// One queued mark of this task, as far as the screen cares.
    struct Queued: Hashable {
        let id: String
        let conflicted: Bool
    }

    static func queued(_ pending: [PendingOperation], taskID: String) -> [Queued] {
        pending.filter { $0.lineMark?.taskID == taskID }
            .map { Queued(id: $0.id, conflicted: $0.conflict != nil) }
    }

    /// Re-read the job when a queued mark LEFT the outbox (sent, replaced or
    /// discarded) or was parked as a conflict — either way the server's line
    /// is no longer what the screen last read. Not for a mark that merely
    /// joined: the screen's own tap already accounts for it.
    static func reloadNeeded(from old: [Queued], to new: [Queued]) -> Bool {
        let now = Dictionary(new.map { ($0.id, $0.conflicted) }, uniquingKeysWith: { $1 })
        return old.contains { previous in
            guard let conflicted = now[previous.id] else { return true }
            return conflicted && !previous.conflicted
        }
    }
}

/// One line as the screen shows it: the server's row, and this person's
/// marks for it that are still on the phone.
struct LineState: Identifiable, Equatable {
    let line: OperationLine
    /// The newest unsent mark — what the line will be once it is sent.
    let waiting: PendingOperation?
    /// A mark whose replay met somebody else's change.
    let conflict: PendingOperation?
    /// Marks the server refused, kept as the record of it.
    let refused: [PendingOperation]

    var id: String { line.id }

    /// The status on screen: the queued mark's while one waits — the web's
    /// offline panel shows its optimistic status the same way — and the
    /// server's otherwise. «Още не е на сървъра» beside it says which.
    var shown: OperationLineStatus { waiting?.lineMark?.lineStatus ?? line.status }
}

/// The words, in one place. VERBATIM from the web's `messages/bg.json`
/// wherever the web has the sentence (named per line); this app's own where
/// it does not, in the same register.
enum FieldOperationText {
    /// `tasks.detail.fieldOperation`.
    static let title = "Земеделска операция"

    /// `ag.map.fieldOp.parcelsComplete`.
    static func progress(done: Int, total: Int) -> String {
        "\(done) / \(total) парцела завършени"
    }

    /// `ag.map.fieldOp.done` / `.skip` / `.reopen`.
    static func verb(_ target: OperationLineStatus) -> String {
        switch target {
        case .done: "Готово"
        case .skipped: "Пропусни"
        case .pending: "Отвори отново"
        case .unknown: ""
        }
    }

    /// What a Voice Control user can say to each — Bulgarian first, as
    /// every input label in the app (`A11y.spokenNames`).
    static func spoken(_ target: OperationLineStatus) -> [String] {
        switch target {
        case .done: A11y.Spoken.done
        case .skipped: A11y.spokenNames("Пропусни", "Skip")
        case .pending: A11y.spokenNames("Отвори отново", "Reopen")
        case .unknown: []
        }
    }

    /// `offline.notOnServer` — beside a line whose status is a queued mark.
    static let notOnServer = "Още не е на сървъра"

    static let kept = "Отбелязването не стигна до сървъра. Запазено е на телефона "
        + "и ще се изпрати автоматично."

    static let cancelledOnPhone = "Отбелязването, което чакаше на телефона, е отменено. "
        + "Нищо не беше изпратено."

    /// A 409 on the live tap. The farm profile's sentence about THIS record
    /// (`FarmProfileConflict`), and what happens next.
    static let conflictLive = "Редът е променен от друг потребител междувременно. "
        + "Отбелязването ви не е записано. Редът е презареден — проверете го "
        + "и отбележете отново, ако е нужно."

    /// `offline.conflict.title` — a replayed mark that met a newer change.
    static let conflictTitle = "Тази задача се промени, докато бяхте офлайн"

    /// `offline.conflict.description`.
    static func conflictDescription(_ label: String) -> String {
        "Промяната ви в опашката за „\(label)“ е в конфликт с по-нова актуализация на сървъра."
    }

    /// `offline.conflict.keepMine` / `.takeServer`.
    static let keepMine = "Запази моята"
    static let takeServer = "Използвай сървъра"

    static let keepMineUnavailable = "Сървърът не съобщи текущата версия на реда, "
        + "затова вашата промяна не може да бъде изпратена отново. Изберете "
        + "«Използвай сървъра» и отбележете реда отново."

    static func refusedQueued(_ status: OperationLineStatus) -> String {
        "Отбелязването «\(status.label)» не беше прието от сървъра."
    }

    static let notPermitted = "Парцелите се отбелязват от изпълнителя на задачата "
        + "или от потребител с права за редакция."

    static let waitingForUser = "Изчакване на потребителския профил…"

    static let noVersion = "Сървърът не изпрати версия на този ред, затова той не "
        + "може да бъде отбелязан безопасно."
}
