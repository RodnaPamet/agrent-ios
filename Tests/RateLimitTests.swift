import Observation
import XCTest
@testable import Agrent

/// The rule for "the server asked us to wait", with every instant passed in.
final class RateLimitGateTests: XCTestCase {

    private let t0 = ContinuousClock.now

    private func at(_ offset: Duration) -> ContinuousClock.Instant {
        t0.advanced(by: offset)
    }

    private func http(_ status: Int, retryAfter seconds: Int?) -> Error {
        APIClient.APIError.http(status: status, code: nil, message: nil, retryAfterSeconds: seconds)
    }

    func testHoldsUntilTheServersMoment() {
        var gate = RateLimitGate()
        XCTAssertTrue(gate.isOpen(at: t0), "open before anything has been absorbed")

        gate.close(for: .seconds(12), at: t0)
        XCTAssertFalse(gate.isOpen(at: at(.milliseconds(11_999))))
        XCTAssertTrue(gate.isOpen(at: at(.seconds(12))))
        XCTAssertEqual(gate.remaining(at: at(.seconds(2))), .seconds(10))
        XCTAssertNil(gate.remaining(at: at(.seconds(13))))
    }

    /// Two requests on one budget can come back with different numbers, and
    /// the one that arrived last is not thereby the truer one. Opening early
    /// buys a guaranteed 429.
    func testALaterShorterAnswerCannotShortenTheWait() {
        var gate = RateLimitGate()
        gate.close(for: .seconds(30), at: t0)
        gate.close(for: .seconds(5), at: at(.seconds(1)))
        XCTAssertFalse(gate.isOpen(at: at(.seconds(10))),
                       "a five-second answer reopened a thirty-second wait")
        XCTAssertEqual(gate.remaining(at: at(.seconds(10))), .seconds(20))

        // A LONGER one does extend it.
        gate.close(for: .seconds(60), at: at(.seconds(10)))
        XCTAssertEqual(gate.remaining(at: at(.seconds(10))), .seconds(60))
    }

    func testReopenOpensItAtOnce() {
        var gate = RateLimitGate()
        gate.close(for: .seconds(30), at: t0)
        gate.reopen()
        XCTAssertTrue(gate.isOpen(at: t0))
        XCTAssertNil(gate.reopensAt)
        XCTAssertEqual(gate, RateLimitGate())
    }

    /// The policy, in one place: the fallback for a 429 with no header, the
    /// floor that stops "0" becoming a hot loop, and ONLY a 429.
    func testWaitPolicy() {
        XCTAssertEqual(RateLimitGate.fallbackSeconds, 60)
        XCTAssertEqual(RateLimitGate.wait(for: http(429, retryAfter: nil)), .seconds(60))
        XCTAssertEqual(RateLimitGate.wait(for: http(429, retryAfter: 0)), .seconds(1))
        XCTAssertEqual(RateLimitGate.wait(for: http(429, retryAfter: 12)), .seconds(12))
        XCTAssertEqual(RateLimitGate.wait(for: http(429, retryAfter: 3600)), .seconds(3600))

        // A 503 carries its wait truthfully and is STILL not a budget: the
        // outbox counts it as an ordinary transient, as the web does.
        let notAWait: [Error] = [
            http(503, retryAfter: 12), http(500, retryAfter: nil), http(408, retryAfter: nil),
            http(400, retryAfter: nil), URLError(.timedOut), URLError(.notConnectedToInternet),
            APIClient.APIError.clientTooOld,
            APIClient.APIError.conflict(currentVersion: 2, expectedVersion: 1),
        ]
        for error in notAWait {
            XCTAssertNil(RateLimitGate.wait(for: error), "\(error) closed the gate")
        }
    }
}

/// A clock a test owns. It moves only when the pause sleeps on it, and by
/// exactly what was asked — so nothing here waits on a real second, and an
/// alarm's timing is a fact rather than a race.
///
/// It honours cancellation the way `Task.sleep` does, by throwing, so a
/// cancelled alarm behaves as it would on the device.
@MainActor
final class FakeRateLimitClock {
    private(set) var now = ContinuousClock.now
    private(set) var sleeps: [Duration] = []

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        sleeps.append(duration)
        advance(by: duration)
    }
}

/// A sleeper that PARKS until the test ends the sleep by hand.
///
/// `FakeRateLimitClock` never suspends, so with it a cancel can land only
/// before the sleep starts — never in the gap this exists to reach: the
/// sleep has finished, and something cancels the alarm before the alarm's
/// own continuation runs. That is a foreground flush arriving at the
/// server's moment, and it is the one case the alarm's post-sleep
/// cancellation check is for.
@MainActor
final class ParkedRateLimitSleep {
    var now = ContinuousClock.now
    private(set) var parked: CheckedContinuation<Void, Never>?

    func sleep(for _: Duration) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { parked = $0 }
    }
}

/// What a callback saw, from inside the alarm's own task.
@MainActor
private final class ReopenProbe {
    var calls = 0
    var cancelledInside: [Bool] = []
    var calledAt: [ContinuousClock.Instant] = []
}

@MainActor
final class RateLimitPauseTests: XCTestCase {

    private func rateLimited(_ seconds: Int?) -> Error {
        APIClient.APIError.http(
            status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: seconds)
    }

    private func makePause(on clock: FakeRateLimitClock) -> RateLimitPause {
        RateLimitPause(now: { clock.now }, sleep: { try await clock.sleep(for: $0) })
    }

    /// THE SELF-CANCEL TRAP, held.
    ///
    /// The outbox's `flush()` disarms before it drains, to supersede an alarm
    /// still waiting. When the alarm is what called it, that disarm must not
    /// cancel the alarm's own task: URLSession would fail the send as
    /// `URLError(.cancelled)`, `isWorthRetrying` would call that retriable,
    /// and a spray would spend an attempt on nothing. The callback here does
    /// exactly what `flush()` does first, and records what it finds.
    func testTheAlarmReopensWithoutCancellingTheFlushItStarts() async {
        let clock = FakeRateLimitClock()
        let pause = makePause(on: clock)
        let probe = ReopenProbe()
        pause.onReopen = { [weak pause] in
            pause?.disarm()
            probe.cancelledInside.append(Task.isCancelled)
            probe.calls += 1
        }

        XCTAssertTrue(pause.absorb(rateLimited(12)))
        XCTAssertTrue(pause.isPaused)
        XCTAssertEqual(pause.remaining, .seconds(12))

        // THE BANNER HEARS THE REOPEN. It reads `remaining`, and it
        // re-renders because the reopen changes an OBSERVED property — not
        // because time passes, which Observation cannot see. Every other
        // assertion here would still pass with the gate marked
        // `@ObservationIgnored`, while the caption stayed up and «Изпрати»
        // stayed hidden after the pause had ended.
        let rerendered = expectation(description: "the reopen reached an observer of `remaining`")
        withObservationTracking {
            _ = pause.remaining
        } onChange: {
            rerendered.fulfill()
        }

        await pause.arm()?.value

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(probe.cancelledInside, [false],
                       "the drain the alarm starts would run in a cancelled task")
        XCTAssertFalse(pause.isPaused)
        XCTAssertNil(pause.gate.reopensAt, "the observed gate was not reopened")
        XCTAssertEqual(clock.sleeps, [.seconds(12)], "slept the server's wait, exactly once")
        // Already fulfilled by now — the change is reported synchronously,
        // inside the alarm — so this returns at once rather than waiting.
        await fulfillment(of: [rerendered], timeout: 1)
    }

    /// A second 429 asks for longer while the first alarm sleeps. The alarm
    /// is not doubled — `arm()` is idempotent — and when it wakes into a
    /// wait that is still in force, it sets the next one instead of calling
    /// back early.
    ///
    /// ── Asserted as a SEQUENCE, not as a state between the two alarms ──
    ///
    /// The first version of this test checked "still paused" right after the
    /// first alarm finished, and failed: the second alarm is queued on the
    /// main actor before the test's own continuation, and this clock sleeps
    /// without a real wait, so it had already run. The claim worth holding is
    /// order-free — one call back, at the server's moment and not at the
    /// first alarm's, after exactly the two sleeps.
    func testAnExtendedPauseReArms() async {
        let clock = FakeRateLimitClock()
        let t0 = clock.now
        let pause = makePause(on: clock)
        let probe = ReopenProbe()
        pause.onReopen = {
            probe.calls += 1
            probe.calledAt.append(clock.now)
        }

        pause.absorb(rateLimited(12))
        let first = pause.arm()
        pause.absorb(rateLimited(30))
        XCTAssertNotNil(first)
        XCTAssertEqual(pause.arm(), first, "a second alarm was set beside the first")
        XCTAssertEqual(pause.remaining, .seconds(30))

        // Every alarm in turn, however far the main actor has already run
        // them: `arm()` hands back the one pending, or nil once reopened.
        // Bounded, so a pause that re-armed forever fails here rather than
        // hanging the suite.
        await first?.value
        for _ in 0..<5 {
            guard let next = pause.arm() else { break }
            await next.value
        }

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(probe.calledAt, [t0.advanced(by: .seconds(30))],
                       "called back at the first alarm's moment, inside the extended wait")
        XCTAssertEqual(clock.sleeps, [.seconds(12), .seconds(18)],
                       "the first alarm did not hand over to a second for the rest")
        XCTAssertFalse(pause.isPaused)
    }

    /// The phone comes back after the moment has passed, and a foreground
    /// flush gets there before the alarm has run. The flush's disarm must
    /// reopen the gate — the moment HAS come — and the cancelled alarm must
    /// not call back as well, or the queue is drained twice.
    func testDisarmReopensAnElapsedGate() async {
        let clock = FakeRateLimitClock()
        let pause = makePause(on: clock)
        let probe = ReopenProbe()
        pause.onReopen = { probe.calls += 1 }

        pause.absorb(rateLimited(12))
        let alarm = pause.arm()
        clock.advance(by: .seconds(13))
        XCTAssertFalse(pause.isPaused, "the moment has passed")
        XCTAssertNotNil(pause.gate.reopensAt, "positive control: nothing has reopened it yet")

        pause.disarm()
        XCTAssertNil(pause.gate.reopensAt, "disarm left an elapsed gate closed")

        await alarm?.value
        XCTAssertEqual(probe.calls, 0, "a cancelled alarm called back")
    }

    /// The same race, one step later: the sleep has ENDED, and the
    /// foreground flush's disarm lands before the alarm's continuation runs.
    ///
    /// `FakeRateLimitClock` cannot reach this — its sleep never suspends, so
    /// a cancel can land only before the sleep starts, where it throws. Here
    /// the test ends the sleep itself and disarms in the same breath; both
    /// run on the main actor, so the alarm resumes only when the test awaits
    /// it. Without the alarm's post-sleep check, the superseded alarm would
    /// reopen the gate and call back a second drain — and clear a handle that
    /// may already belong to a newer alarm.
    func testAnAlarmCancelledAfterItsSleepEndedDoesNotCallBack() async throws {
        let clock = ParkedRateLimitSleep()
        let pause = RateLimitPause(now: { clock.now }, sleep: { try await clock.sleep(for: $0) })
        let probe = ReopenProbe()
        pause.onReopen = { probe.calls += 1 }

        pause.absorb(rateLimited(12))
        let alarm = try XCTUnwrap(pause.arm())
        // Bounded, so an alarm that never reached its sleep fails here
        // rather than hanging the suite.
        var spins = 0
        while clock.parked == nil, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        let parked = try XCTUnwrap(clock.parked, "the alarm never reached its sleep")

        clock.now = clock.now.advanced(by: .seconds(12))
        parked.resume()     // the sleep is over; its continuation queues behind this test
        pause.disarm()      // and the foreground flush gets there first
        XCTAssertFalse(pause.isPaused, "positive control: the disarm found the moment passed")

        await alarm.value
        XCTAssertEqual(probe.calls, 0, "a superseded alarm called back after its sleep")
    }

    /// Disarming DURING a wait cancels the alarm and leaves the pause in
    /// force — which is why `flush()` re-arms when it finds itself paused.
    func testDisarmDuringAWaitLeavesItClosedAndArmSetsAnotherAlarm() async {
        let clock = FakeRateLimitClock()
        let pause = makePause(on: clock)
        let probe = ReopenProbe()
        pause.onReopen = { probe.calls += 1 }

        pause.absorb(rateLimited(12))
        let cancelled = pause.arm()
        pause.disarm()
        XCTAssertTrue(pause.isPaused)

        let rearmed = pause.arm()
        XCTAssertNotNil(rearmed)
        XCTAssertNotEqual(rearmed, cancelled)
        await cancelled?.value
        await rearmed?.value
        XCTAssertEqual(probe.calls, 1, "exactly one call back, from the alarm that was not cancelled")
        XCTAssertFalse(pause.isPaused)
    }

    /// Only a 429 closes it — which is what lets the outbox's catch treat
    /// `absorb` returning true as "leave this item alone and stop".
    func testOnlyA429ClosesIt() {
        let clock = FakeRateLimitClock()
        let pause = makePause(on: clock)
        let others: [Error] = [
            APIClient.APIError.http(status: 503, code: nil, message: nil, retryAfterSeconds: 12),
            APIClient.APIError.http(status: 500, code: nil, message: nil),
            APIClient.APIError.http(status: 408, code: nil, message: nil),
            APIClient.APIError.http(status: 400, code: "BAD_REQUEST", message: nil),
            URLError(.notConnectedToInternet),
            APIClient.APIError.notSignedIn,
        ]
        for error in others {
            XCTAssertFalse(pause.absorb(error), "\(error) was absorbed")
            XCTAssertFalse(pause.isPaused, "\(error) paused the queue")
        }
        XCTAssertNil(pause.arm(), "an alarm with nothing to wait for")

        XCTAssertTrue(pause.absorb(rateLimited(nil)))
        XCTAssertEqual(pause.remaining, .seconds(RateLimitGate.fallbackSeconds),
                       "a 429 without Retry-After waits the fallback")
    }

    /// "0" is a real answer from the auth limiter. Without the floor, flush →
    /// 429 → flush would spend the budget it is waiting on.
    func testAZeroWaitStillPausesForASecond() {
        let clock = FakeRateLimitClock()
        let pause = makePause(on: clock)
        XCTAssertTrue(pause.absorb(rateLimited(0)))
        XCTAssertEqual(pause.remaining, .seconds(1))
    }

    /// The message budget's pause exists already, and it never sends on its
    /// own: a message is a deliberate act addressed to somebody.
    func testTheMessagesPauseNeverCallsBack() {
        XCTAssertNil(RateLimitPause.messages.onReopen)
        XCTAssertFalse(RateLimitPause.messages === OutboxStore.shared.pause,
                       "messages and the outbox draw on different budgets")
    }
}
