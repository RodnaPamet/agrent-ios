import Foundation
import Observation

/// Drains the outbox.
///
/// ── Only the signed-in user's items, ever ──
///
/// `pending` holds what belongs to the user signed in NOW, and the drain
/// sends nothing else (agri-saas#1191 P0.9). Another account's items are
/// PARKED: still on disk, tagged with their owner, invisible to this one —
/// not in the banner, not in the count, not sent — and they come back when
/// their owner signs in again. Dropping them would destroy the only copy of
/// a record of regulated work; sending them would file it under the wrong
/// person (see `PendingOperation.ownerUserID`).
@Observable
@MainActor
final class OutboxStore {
    static let shared = OutboxStore()

    /// The signed-in user's items. Never anybody else's.
    private(set) var pending: [PendingOperation] = []
    private(set) var isFlushing = false

    /// Something was queued WHILE a flush was running.
    ///
    /// The guard on `flush` used to just return, which is correct for
    /// "two triggers fired at once" and wrong for "new work arrived
    /// mid-drain" — the second case silently skipped the new item until
    /// some later trigger happened to fire. Caught by a probe that
    /// enqueued and flushed in the same breath and saw attempts stay at
    /// zero.
    private var needsAnotherPass = false

    /// The whole queue waits when the server says so — ONE pause, in memory.
    ///
    /// ── Not a not-before date on each item ──
    ///
    /// The budget is the phone's public IP, not the item: every operation
    /// behind the first 429 would meet the same answer, which is why the web
    /// stops the whole pass too. And `pending` is re-read from disk on every
    /// refresh, so per-item state would have to be PERSISTED — as a wall-clock
    /// `Date`, exposed to every clock change across launches — to save at most
    /// one request after a relaunch inside a window of a minute.
    ///
    /// Persisting would also have had a trap worth writing down for whoever
    /// wants it anyway: a new NON-optional field with a default throws
    /// `keyNotFound` on every row already on disk, and `all()`'s `try?` would
    /// then silently HIDE every queued spray — still on disk, never sent,
    /// never shown. Measured in scratch. Only an Optional field is safe.
    let pause = RateLimitPause()

    /// The server has said this BUILD is too old to serve: a 426, which its
    /// version gate answers before any route runs (agrent-ios#168).
    ///
    /// ── Remembered in memory, for the life of the process ──
    ///
    /// It describes the binary, not the work and not the person, so nothing a
    /// pass, an Изход or a sign-in does can change it. Installing a newer
    /// build can, and that ends this process. Once an answer has said it,
    /// launch, the return to the foreground, «Изпрати» and the pause's alarm
    /// stop asking: each would buy the same 426, and the queue on disk is
    /// exactly what the updated app will send. (The web's drain keeps no such
    /// memory, so it asks again on every trigger.)
    ///
    /// NOT persisted. A relaunch asks once more, which costs one request and
    /// is the way back should the server's floor ever come down again.
    ///
    /// NOT cleared by `reset()`, unlike the pause. The next person to sign in
    /// on this phone runs the same build, and the server would answer their
    /// queue exactly as it answered this one.
    private(set) var isClientTooOld = false

    /// Remember a 426 if `error` is one, and say whether it was.
    ///
    /// The drain's stop, and also the way the live writes report one: the
    /// spray sheet's save and a parcel line's tap are this same build asking
    /// the same server, so what they learn is true of the queue too. Fed in
    /// like the sheet's 429 (`pause.absorb`), so the banner can say why
    /// nothing is being sent before a tap on «Изпрати» buys the same answer.
    @discardableResult
    func absorbClientTooOld(_ error: Error) -> Bool {
        guard case APIClient.APIError.clientTooOld = error else { return false }
        isClientTooOld = true
        return true
    }

    /// Seams for `SignOutHygieneTests`: the queue on disk, who is signed in,
    /// and how one item is sent. The app uses the real three.
    @ObservationIgnored private let queue: PendingOperations
    @ObservationIgnored private let currentOwner: () -> String?
    @ObservationIgnored private let send: (PendingOperation) async throws -> Void
    @ObservationIgnored private let identify: () async -> Void

    /// The identity is read on EVERY use, never captured: the same store
    /// outlives every session on the phone.
    ///
    /// `identify` runs when a drain finds nobody's identity known. Without it
    /// the launch flush of the first run after this build — tokens, no stored
    /// owner yet — would find nothing to send, and nothing would ask again
    /// until the next return to the foreground.
    init(
        queue: PendingOperations = .shared,
        currentOwner: @escaping () -> String? = { SessionIdentity.shared.userID },
        identify: @escaping () async -> Void = { _ = await CurrentUserStore.shared.load() },
        send: @escaping (PendingOperation) async throws -> Void = OutboxStore.post
    ) {
        self.queue = queue
        self.currentOwner = currentOwner
        self.identify = identify
        self.send = send
        // Whatever reopens the pause drains the queue: the alarm, at the
        // server's moment. Weakly, for form — the store is a singleton.
        pause.onReopen = { [weak self] in await self?.flush() }
    }

    static func post(_ item: PendingOperation) async throws {
        switch replay(for: item) {
        case .create(let path, let key):
            // THE SAME KEY, every time, forever. This is what makes the
            // create safe — a replay of an operation the server already
            // accepted returns the original rather than creating a second.
            _ = try await APIClient.shared.postRaw(path, body: item.payload, idempotencyKey: key)
        case .mark(let path, let seenVersion):
            // THE SAME VERSION, every time — the one the operator saw. This
            // is what makes the mark safe: their own success replays as 200
            // `alreadyApplied`, and anybody else's change since answers 409,
            // which the drain parks as a conflict (#138).
            _ = try await APIClient.shared.patchRaw(path, body: item.payload, ifMatch: seenVersion)
        case nil:
            throw Unsendable()
        }
    }

    /// How one queued row goes out — decided here, PURE, so a test can read
    /// the method, the path, the key and the If-Match of a replay without a
    /// network (there is no URLProtocol seam in the unit suite).
    enum Replay: Equatable {
        /// `POST`, keyed by the row's id.
        case create(path: String, idempotencyKey: String)
        /// `PATCH`, guarded by the version the operator SAW — never a key,
        /// since the route reads none.
        case mark(path: String, seenVersion: Int)
    }

    nonisolated static func replay(for item: PendingOperation) -> Replay? {
        switch item.target {
        case .create(let locationID):
            return .create(path: LocationsAPI.operationsPath(locationID), idempotencyKey: item.id)
        case .mark(let mark):
            return .mark(path: FieldOperationAPI.linePath(taskID: mark.taskID, lineID: mark.lineID),
                         seenVersion: mark.seenVersion)
        case nil:
            return nil
        }
    }

    /// A row with no destination — neither a location nor a line. Nothing in
    /// this app writes one; if a damaged file ever reads as one, the drain
    /// refuses it like any final answer instead of inventing a route.
    struct Unsendable: Error {}

    /// May the user signed in as `owner` see and send `item`?
    ///
    /// Pure, because it is the whole rule. FAILS CLOSED: with nobody's
    /// identity known — between a sign-in and its first `/me`, or the first
    /// launch after this build — nothing belongs to anybody, because "send
    /// everything" is precisely the mistake (the web made it, #1005). An
    /// unowned item belongs to whoever is known to be signed in; see
    /// `PendingOperation.ownerUserID`.
    nonisolated static func belongs(_ item: PendingOperation, to owner: String?) -> Bool {
        guard let owner else { return false }
        return item.ownerUserID == nil || item.ownerUserID == owner
    }

    /// Back to a fresh launch — part of `SessionReset`. The in-memory list
    /// and the pause only: the QUEUE ON DISK is left exactly as it is, which
    /// is what parks the departing user's items rather than destroying them.
    /// `isClientTooOld` stays as it is too: it belongs to the build, which
    /// an Изход does not change.
    func reset() {
        pending = []
        needsAnotherPass = false
        pause.reset()
    }

    /// Items the server has REFUSED, which no amount of retrying will fix.
    ///
    /// Kept rather than discarded. A queued spray is a record of work that
    /// actually happened in a field, and deleting it because the server
    /// said no would destroy the only copy — the farmer would be left with
    /// neither the record nor the knowledge that it was lost.
    var refused: [PendingOperation] { pending.filter { $0.lastError != nil && $0.attempts > 0 && $0.isRefused } }

    var sendable: [PendingOperation] { pending.filter(\.awaitsSend) }

    /// Marks whose replay met somebody else's change, waiting for the
    /// operator to say which stands (#138). Neither waiting nor refused.
    var conflicts: [PendingOperation] { pending.filter { $0.conflict != nil } }

    func refresh() async {
        let owner = currentOwner()
        // Pre-attribution rows become the signed-in user's — once, on disk —
        // so they cannot drift to a third account later.
        if let owner { await queue.claimUnowned(for: owner) }
        let all = await queue.all()
        // Re-read AFTER the await: an Изход during it must not publish the
        // departing user's list into the next one's banner.
        guard currentOwner() == owner else { return }
        pending = all.filter { Self.belongs($0, to: owner) }
    }

    func enqueue(_ operation: PendingOperation) async {
        await queue.enqueue(operation)
        await refresh()
    }

    // MARK: - Parcel-line marks (#138)

    /// Queue a mark, REPLACING any unsent mark for the same line.
    ///
    /// The web's #934, for the same reason. A mark is the absolute state of
    /// one existing row, so the newest one is the whole intent: «Готово» then
    /// «Отвори отново» with no signal means "pending", and replaying both
    /// would land the DONE first — a stock deduction and a ДНЕВНИК row that
    /// un-completing does not reverse — and then meet a 409 against the
    /// operator's own write. Two queued marks for one line are never two
    /// pieces of work.
    ///
    /// The new row is written FIRST and the old removed after: a crash
    /// between the two leaves a duplicate of one state, never a hole.
    func enqueueMark(_ operation: PendingOperation) async {
        await queue.enqueue(operation)
        if let mark = operation.lineMark {
            await supersedeMarks(taskID: mark.taskID, lineID: mark.lineID, keeping: operation.id)
        } else {
            await refresh()
        }
    }

    /// Drop this person's UNSENT marks for one line — after a tap whose
    /// outcome makes them stale, whatever that outcome was: it landed, it
    /// met a conflict, it was refused, or it was queued in their place.
    ///
    /// What it NEVER touches, and why each matters:
    ///   - a CONFLICT: it is waiting for the operator's decision, and
    ///     deleting it answers that question for them;
    ///   - a REFUSED row: a record of something the server said, kept rather
    ///     than discarded for the reason `refused` gives;
    ///   - anybody else's row: `pending` holds only the signed-in person's,
    ///     and with nobody known it is empty — FAIL CLOSED, so a guard that
    ///     cannot tell whose work it is touches none (the web's #1005).
    func supersedeMarks(taskID: String, lineID: String, keeping kept: String?) async {
        await refresh()
        let stale = pending.filter {
            $0.id != kept && $0.awaitsSend
                && $0.lineMark?.taskID == taskID && $0.lineMark?.lineID == lineID
        }
        for item in stale { await queue.remove(item.id) }
        await refresh()
    }

    /// «Запази моята» — the operator's decision that THEIR mark stands.
    ///
    /// Re-queued at the version the 409 reported, so it is accepted over the
    /// change it met — deliberately, this time, by a person who was shown
    /// the conflict. If the line has moved AGAIN since, that version is stale
    /// too and the replay parks a fresh conflict: a third person's change is
    /// never overwritten by a decision made about the second one's.
    ///
    /// Sent by the ordinary drain, not by a send of its own: it is queued
    /// work again, so the pause, the owner check and the stop on no signal
    /// all apply, and with no signal it simply waits like any other mark.
    ///
    /// Decided on the row as it is on disk (`PendingOperations.requeueConflict`),
    /// not on `pending`: a second tap arriving while the first is still
    /// writing would otherwise write a stale copy over the first one's result.
    func keepMine(_ id: String) async {
        guard await queue.requeueConflict(id, owner: currentOwner()) else { return }
        await refresh()
        await flush()
    }

    /// «Използвай сървъра» — the server's state stands and the queued mark
    /// is discarded. Only a parked conflict, and only the signed-in person's:
    /// this must never become a way to delete work that could still be sent.
    func takeServer(_ id: String) async {
        guard await queue.discardConflict(id, owner: currentOwner()) else { return }
        await refresh()
    }

    /// Send what can be sent, oldest first.
    ///
    /// Stops at the first RETRIABLE failure rather than working through the
    /// rest: if the network is down for one it is down for all, and
    /// hammering the queue would spend a farmer's battery to learn the same
    /// thing five times. A refusal does not stop the drain, because it is
    /// specific to that one item.
    func flush() async {
        // ── NOTHING GOES OUT FROM A BUILD THE SERVER HAS RETIRED (#168) ──
        //
        // Every request would meet the same 426, and only installing a newer
        // build changes that — so every trigger is a no-op, with no spinner,
        // until then. Checked before the pause: when the pause reopens there
        // is still nothing to send, so there is no alarm worth arming.
        guard !isClientTooOld else { return }
        // ── NOTHING GOES OUT WHILE THE SERVER HAS ASKED US TO WAIT ──
        //
        // A request sent before the server's moment cannot succeed; it buys a
        // guaranteed 429 and spends a slot of the budget being waited for. So
        // launch, the return to the foreground and «Изпрати» are no-ops for
        // the length of a pause — and there is no spinner for a request that
        // will not be made. The alarm is the trigger that remains, and
        // `arm()` makes sure there is one.
        guard !pause.isPaused else {
            pause.arm()
            return
        }
        guard !isFlushing else {
            // Not dropped — deferred. The running pass will take another
            // turn rather than this work waiting for an unrelated trigger.
            needsAnotherPass = true
            return
        }
        // This pass supersedes an alarm still waiting. When the ALARM is what
        // called this, it has already cleared its own handle, so this finds
        // nothing to cancel — see `RateLimitPause` for what cancelling it
        // would have cost.
        pause.disarm()
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            needsAnotherPass = false
            await drain()
            // A pause that closed during the pass ends the loop: work queued
            // meanwhile waits for the alarm rather than walking into it. So
            // does a 426 met during it: another turn would send the first
            // item again, to be told the same thing.
        } while needsAnotherPass && !pause.isPaused && !isClientTooOld
    }

    private func drain() async {
        if currentOwner() == nil { await identify() }
        await refresh()

        // Refused rows and parked conflicts are never sent by a pass: one
        // needs a person to read it, the other a person to decide it.
        for listed in pending where listed.awaitsSend {
            // The pause can close from OUTSIDE this pass — the operation
            // sheet feeds it, because its live save spends the same budget —
            // and the next send would only confirm it. A live write can learn
            // of a 426 the same way, and the next send would confirm that too.
            if pause.isPaused || isClientTooOld { break }
            // ── THE ROW AS IT IS NOW, NOT AS IT WAS LISTED (#138) ──
            //
            // A tap on a line during the pass REPLACES that line's unsent
            // mark (`enqueueMark`), and the list was read before it. Sending
            // the listed copy would land the mark the operator had just
            // replaced — a «Готово», with its stock deduction, they took
            // back — and walk the newer one into a 409 against it. Gone, or
            // no longer waiting: skip it. What this cannot see is a row
            // replaced while ITS OWN request is in the air; the write-back
            // below is guarded for that.
            guard var item = await queue.row(listed.id), item.awaitsSend else { continue }
            // ── WHOSE, CHECKED PER ITEM, NOT ONCE PER PASS ──
            //
            // `pending` was filtered when the pass began. A sign-out and a
            // sign-in DURING the pass would otherwise send the rest of A's
            // list under B's token — each send is an `await`, and a slow
            // field connection makes them long ones. Stop, touch nothing.
            if !Self.belongs(item, to: currentOwner()) { break }
            do {
                try await send(item)
                await queue.remove(item.id)
            } catch {
                // ── A 429 IS ABSORBED FIRST, AND THE ITEM IS NOT TOUCHED ──
                //
                // Not this item's fault: the budget is the phone's, and the
                // server's limiter runs before the route is reached, so
                // nothing about this operation was even looked at. No attempt
                // is spent, `lastError` is not rewritten, nothing is written
                // to disk. The pass stops, and the pause wakes the queue at
                // the server's moment.
                //
                // THE ORDER IS THE FIX. Absorbing after the bump would count
                // every 429 of a reconnect burst against the item — harmless
                // only while nothing caps attempts, and the web, which does
                // cap them, excludes 429 for exactly that reason: a long
                // enough burst would silently drop queued work. A test holds
                // this order.
                if pause.absorb(error) { break }

                // ── NO SESSION IS NOT THIS ITEM'S FAULT EITHER ──
                //
                // `send` throws `notSignedIn` before a request leaves — no
                // token in the Keychain, or a refresh the server rejected —
                // so the server has seen nothing of this operation. The retry
                // policy calls it final all the same, and a refusal does not
                // stop the pass: every queued spray would be stamped REFUSED
                // in one go. Refused is permanent — never sent again, and
                // after the next sign-in the banner would report «не бяха
                // приети от сървъра» about records the server never received.
                //
                // The pause is what made this reachable. Its alarm is the one
                // trigger that outlives `MainTabView`, so a farmer who signs
                // out inside a pause is drained with no token. Stop and touch
                // nothing; the next sign-in's launch flush sends them.
                if case APIClient.APIError.notSignedIn = error { break }

                // ── A 426 IS ABOUT THE BUILD, NOT THIS ITEM (#168) ──
                //
                // The server's version gate answers before any route runs —
                // "the request was not processed; it is NOT a payload
                // rejection", in the spec's words — so it says nothing about
                // this operation, and every item behind it would get the same
                // answer. The retry policy calls it final, and before this stop
                // that was the whole story: refused, the pass went on, and
                // every queued spray and parcel-line mark was stamped REFUSED
                // in one pass. Permanently — the updated app would never send
                // them — under a banner saying the server had declined work it
                // never looked at.
                //
                // So, as for no session, and BEFORE the bump: no attempt spent,
                // `lastError` not rewritten, not refused, not parked as a
                // conflict, nothing written to disk. The pass stops, and
                // `isClientTooOld` keeps every later trigger from asking again
                // until a newer build is installed, which sends the queue as it
                // stands. The web does the same in `sync.ts` (agri-saas#938).
                if absorbClientTooOld(error) { break }

                item.attempts += 1
                item.lastAttemptAt = Date()
                item.lastError = UserMessage.text(for: error)
                if let conflict = PendingOperation.Conflict(replayOf: item, failedWith: error) {
                    // ── A STALE MARK IS A CONFLICT, NOT A REFUSAL (#138) ──
                    //
                    // The line moved on while the mark sat here — somebody
                    // else's change, since a replay of the operator's OWN
                    // success comes back 200 `alreadyApplied`. Parked for
                    // them to decide, with the server's version kept for
                    // «Запази моята». Never refused (refused is "the server
                    // will say no again", and this is not that), and never
                    // retried by a pass: a blind resend would 409 again, or
                    // clobber the other change once versions lined up. Like
                    // a refusal it is this row's alone, so the pass goes on.
                    item.conflict = conflict
                } else {
                    item.isRefused = !PendingOperations.isWorthRetrying(error)
                }
                // Only if the row is still there: a newer mark for the same
                // line, or «Използвай сървъра», may have removed it while its
                // send was in flight, and writing it back would resurrect it.
                await queue.updateIfPresent(item)
                if item.awaitsSend {
                    // Network is down; the rest will fail identically.
                    break
                }
            }
        }
        await refresh()
    }
}
