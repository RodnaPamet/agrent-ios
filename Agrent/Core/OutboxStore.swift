import Foundation
import Observation

/// Drains the outbox.
@Observable
@MainActor
final class OutboxStore {
    static let shared = OutboxStore()

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

    private init() {
        // Whatever reopens the pause drains the queue: the alarm, at the
        // server's moment. Weakly, for form — the store is a singleton.
        pause.onReopen = { [weak self] in await self?.flush() }
    }

    /// Items the server has REFUSED, which no amount of retrying will fix.
    ///
    /// Kept rather than discarded. A queued spray is a record of work that
    /// actually happened in a field, and deleting it because the server
    /// said no would destroy the only copy — the farmer would be left with
    /// neither the record nor the knowledge that it was lost.
    var refused: [PendingOperation] { pending.filter { $0.lastError != nil && $0.attempts > 0 && $0.isRefused } }

    var sendable: [PendingOperation] { pending.filter { !$0.isRefused } }

    func refresh() async {
        pending = await PendingOperations.shared.all()
    }

    func enqueue(_ operation: PendingOperation) async {
        await PendingOperations.shared.enqueue(operation)
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
            // meanwhile waits for the alarm rather than walking into it.
        } while needsAnotherPass && !pause.isPaused
    }

    private func drain() async {
        await refresh()

        for var item in pending where !item.isRefused {
            // The pause can close from OUTSIDE this pass — the operation
            // sheet feeds it, because its live save spends the same budget —
            // and the next send would only confirm it.
            if pause.isPaused { break }
            do {
                _ = try await APIClient.shared.postRaw(
                    LocationsAPI.operationsPath(item.locationID),
                    body: item.payload,
                    // THE SAME KEY, every time, forever. This is what makes
                    // the whole queue safe — a replay of an operation the
                    // server already accepted returns the original rather
                    // than creating a second.
                    idempotencyKey: item.id
                )
                await PendingOperations.shared.remove(item.id)
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

                item.attempts += 1
                item.lastAttemptAt = Date()
                item.lastError = UserMessage.text(for: error)
                item.isRefused = !PendingOperations.isWorthRetrying(error)
                await PendingOperations.shared.update(item)
                if !item.isRefused {
                    // Network is down; the rest will fail identically.
                    break
                }
            }
        }
        await refresh()
    }
}
