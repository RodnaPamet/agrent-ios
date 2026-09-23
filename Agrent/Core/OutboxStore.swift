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

    private init() {}

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
        guard !isFlushing else {
            // Not dropped — deferred. The running pass will take another
            // turn rather than this work waiting for an unrelated trigger.
            needsAnotherPass = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            needsAnotherPass = false
            await drain()
        } while needsAnotherPass
    }

    private func drain() async {
        await refresh()

        for var item in pending where !item.isRefused {
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
