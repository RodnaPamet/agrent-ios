import Foundation
import Observation

/// "The server has asked us to wait": the rule, held once per budget and
/// woken on time.
///
/// ── What the server sends, read in its source (agri-saas 11b00118) ──
///
/// `Retry-After` in whole seconds, never the date form. The middleware
/// limiter and the read limiter send at least 1. The auth limiter
/// (`/api/auth/*`, which includes the token refresh) does not clamp and can
/// send "0". A thrown `RateLimitedError` goes out with no header at all. So
/// "no header" and "zero" are both real answers and both need a rule — this
/// file is where the rules live, and `APIClient.retryAfterSeconds` stays a
/// parser.
///
/// ── Whose budget it is ──
///
/// NOT the item's, and not the operator's. The outbox's route draws on the
/// server's default mutation limiter, and that is keyed by public IP alone:
/// on a carrier NAT it is shared with strangers. Messages draw on one
/// 60-a-minute budget for the whole sending farm, every colleague and every
/// device. So a 429 is a fact about where the phone stands in a queue, and it
/// is held ONCE per budget rather than per request — the outbox owns one
/// pause, and messages share `RateLimitPause.messages`.
///
/// ── Split in two ──
///
/// `RateLimitGate` is the rule. It is pure and every instant is passed in,
/// so it is tested without a clock. `RateLimitPause` is the gate plus an
/// alarm that wakes at the server's moment, and it is the only part here
/// that sleeps.
struct RateLimitGate: Equatable, Sendable {
    /// The wait when a 429 came WITHOUT `Retry-After` — a proxy, or the
    /// server's thrown error. One window of the budgets this app meets (the
    /// mutation and message limits are per minute), and the web's own
    /// default for the same case.
    static let fallbackSeconds = 60

    /// When the server said it would answer again. nil once reopened.
    private(set) var reopensAt: ContinuousClock.Instant?

    /// How long a failure asks to be waited out — nil unless it is a 429.
    ///
    /// ONLY a 429. A 503 can carry `Retry-After` too, and the error carries
    /// it truthfully, but a server that is down is not a budget: the outbox
    /// keeps counting a 503 as an ordinary transient, as the web does.
    ///
    /// FLOORED AT ONE SECOND. "0" is real, and a wait of nothing turns
    /// flush → 429 → flush into a loop that spends the very budget it is
    /// waiting on. The one-hour ceiling is the parser's, already applied.
    static func wait(for error: Error) -> Duration? {
        guard case APIClient.APIError.http(let status, _, _, _, let seconds) = error,
              status == 429
        else { return nil }
        return .seconds(max(seconds ?? fallbackSeconds, 1))
    }

    /// Closed until `now + wait`, or until a later moment already in force.
    ///
    /// A SHORTER ANSWER ARRIVING SECOND NEVER SHORTENS THE WAIT. Two
    /// requests on one budget can come back with different numbers — the
    /// server's window frees one slot at a time — and whichever arrived last
    /// is not thereby the truer one. Opening early buys a guaranteed 429.
    mutating func close(for wait: Duration, at now: ContinuousClock.Instant) {
        let candidate = now.advanced(by: wait)
        if let reopensAt, reopensAt >= candidate { return }
        reopensAt = candidate
    }

    /// The time left at `now`, or nil once the moment has come.
    func remaining(at now: ContinuousClock.Instant) -> Duration? {
        guard let reopensAt, reopensAt > now else { return nil }
        return now.duration(to: reopensAt)
    }

    func isOpen(at now: ContinuousClock.Instant) -> Bool {
        remaining(at: now) == nil
    }

    mutating func reopen() {
        reopensAt = nil
    }
}

/// A `RateLimitGate` with an alarm on it.
///
/// ── `ContinuousClock`, and never `Date` ──
///
/// The server's window runs in real time, whether or not this phone is
/// asleep. `ContinuousClock` keeps counting while the device sleeps, which is
/// that; `SuspendingClock` would stretch the wait by however long the phone
/// was in a pocket, and `Date` moves when a person — or the network — changes
/// the clock. It is also `Task.sleep(for:)`'s own default, so the alarm and
/// the gate read the same time. Nothing here is persisted: killed during a
/// pause, the app forgets it, and the next launch spends at most one request
/// to be told again.
///
/// ── The trap in the alarm, and why the handle is cleared FIRST ──
///
/// A drain must cancel an alarm it has superseded, so that the queue is not
/// sent twice. But when the ALARM is what started the drain, cancelling it
/// cancels the task the drain is running in — URLSession then fails the send
/// as `URLError(.cancelled)`, which `isWorthRetrying` calls retriable, and the
/// spray spends an attempt on nothing. So the alarm sets `alarm = nil` before
/// it calls back, and `disarm()` finds nothing to cancel. The test that holds
/// it records `Task.isCancelled` from inside the callback.
///
/// ── No `deinit`, because none is needed ──
///
/// Both pauses live as long as the app — the outbox's is held by a singleton,
/// the messages' is static — and the alarm holds `self` weakly: a pause that
/// did go away would be found missing when the alarm woke, and the alarm
/// would do nothing. A deinit COULD cancel it. The obvious objection — the
/// deinit of a `@MainActor` class is nonisolated, so it cannot touch
/// `alarm` — is wrong: Swift 6.3.3 in Swift 6 mode accepts
/// `deinit { alarm?.cancel() }` in exactly this class shape, checked with
/// `swiftc -typecheck -swift-version 6`. Left out as unneeded, not as
/// impossible.
///
/// ── No background task ──
///
/// The waits that matter are a minute or less, and iOS promises nothing about
/// when a `BGTaskScheduler` refresh runs. A suspended app suspends the alarm
/// with it; on return, `ContinuousClock` has counted the time away, so the
/// alarm fires at once if the moment has passed and keeps sleeping if not.
/// That is read from the clock's contract and NOT yet watched on a device —
/// the foreground flush is the backstop either way, since it drains once the
/// moment has passed whether or not the alarm has woken.
@Observable
@MainActor
final class RateLimitPause {
    /// The farm's MESSAGE budget: one per tenant, across every thread,
    /// colleague and device, so one pause for the whole app. Its `onReopen`
    /// stays nil and is meant to — a message is a deliberate act addressed to
    /// somebody, and nothing sends one on the app's own schedule. Here now so
    /// that messaging meets a pause that already exists instead of growing a
    /// second one.
    static let messages = RateLimitPause()

    /// OBSERVED, so a view reading `remaining` or `isPaused` re-renders when
    /// the pause closes and when the alarm reopens it.
    private(set) var gate = RateLimitGate()

    /// What to do when the server's moment comes. The outbox drains.
    @ObservationIgnored var onReopen: (@MainActor () async -> Void)?

    @ObservationIgnored private var alarm: Task<Void, Never>?

    /// Injected so a test can own time: its clock moves when its sleeper
    /// says so, and no test in this suite waits on a real second.
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    init(
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// How long is left, or nil when nothing is being waited for.
    var remaining: Duration? { gate.remaining(at: now()) }

    var isPaused: Bool { remaining != nil }

    /// Take a failure's wait, if it has one. True only for a 429 — which is
    /// how a caller knows to stop, and to leave what it was sending alone.
    @discardableResult
    func absorb(_ error: Error) -> Bool {
        guard let wait = RateLimitGate.wait(for: error) else { return false }
        gate.close(for: wait, at: now())
        // The one line a paused queue leaves on a device. No other line logs
        // an `APIError.http` today — `Log.failure` sees transport errors
        // only — so without it a quiet outbox shows nothing but the `← 429`
        // of the response. Both halves are safe under `Log`'s rules: the wait
        // applied here, after the fallback and the floor, and the summary,
        // which carries the server's own number and drops its prose.
        Log.api.info(
            "rate-limit pause \(wait.components.seconds, privacy: .public)s: \(Log.summary(for: error), privacy: .public)"
        )
        arm()
        return true
    }

    /// Make sure something will wake at the server's moment.
    ///
    /// IDEMPOTENT: an alarm already set is returned rather than joined by a
    /// second one. If the pause was extended while it slept, it finds itself
    /// still paused on waking and sets the next one. The handle is returned
    /// so a test can await the alarm instead of guessing at its timing.
    @discardableResult
    func arm() -> Task<Void, Never>? {
        if let alarm { return alarm }
        guard let wait = remaining else { return nil }
        let sleep = self.sleep
        let task = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            // Cancelled while its sleep was finishing: whoever cancelled it
            // is running the pass, and the handle may already belong to a
            // newer alarm, which this must not clear.
            guard !Task.isCancelled, let self else { return }
            // BEFORE the callback — see the header. The callback's drain
            // disarms first, and it must find nothing to cancel.
            self.alarm = nil
            if self.isPaused {
                self.arm()
                return
            }
            self.gate.reopen()
            await self.onReopen?()
        }
        alarm = task
        return task
    }

    /// Cancel the alarm — a pass that is starting supersedes it — and reopen
    /// the gate if its moment has already come.
    func disarm() {
        alarm?.cancel()
        alarm = nil
        if gate.reopensAt != nil, !isPaused { gate.reopen() }
    }
}
