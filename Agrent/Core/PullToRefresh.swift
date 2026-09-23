import Foundation

/// How long a pull-to-refresh gesture is allowed to hold the spinner.
///
/// ── Why the gesture is bounded and the work is not ──
///
/// `.refreshable` holds its spinner until the async closure returns. In a
/// cache-first app that is the wrong coupling: the screen already has
/// content, so the refresh is an attempt to improve it, not a load the
/// reader is waiting on. Offline the attempt takes the full request
/// timeout, and the owner described the result as the refresh being
/// "broken" — a spinner that hangs for fifteen seconds and then leaves the
/// same rows behind.
///
/// So the gesture returns after a short bound and the work continues
/// behind it, publishing whenever it lands. Online the work almost always
/// finishes first and the bound is never reached; offline the spinner ends
/// promptly and the staleness banner keeps telling the truth about what is
/// on screen.
///
/// Two seconds because it is long enough for a good connection to win the
/// race outright — so the common case still shows a spinner that means
/// something — and short enough that a farmer with no signal is not left
/// holding a gesture.
enum PullToRefresh {
    static let gestureBound: Double = 2

    /// Run `work`, but stop holding the caller after `seconds`.
    ///
    /// The work is a detached-lifetime `Task`, so cancelling the waiter
    /// does not cancel the refresh — only the waiting.
    static func bounded(
        _ seconds: Double = gestureBound,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        let task = Task { await work() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            // Cancels whichever waiter is still pending. `task` is owned
            // above and keeps running regardless.
            group.cancelAll()
        }
    }
}
