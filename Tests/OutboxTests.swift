import XCTest
@testable import Agrent

/// The outbox exists because a spray recorded in a field survives only as
/// long as the sheet stays open. Measured offline before building it: the
/// write fails in 0.0s with «Няма връзка със сървъра.», nothing partial,
/// data intact — until the sheet is dismissed or the app is killed.
final class OutboxRetryPolicyTests: XCTestCase {

    /// Queueing a REFUSAL is worse than failing. It sits in the outbox
    /// retrying forever while the farmer is told their spray is "waiting
    /// to send", when the server has already declined it.
    func testAServerRefusalIsNeverQueued() {
        for status in [400, 401, 403, 404, 409, 422, 426] {
            let error = APIClient.APIError.http(status: status, code: nil, message: nil)
            XCTAssertFalse(PendingOperations.isWorthRetrying(error),
                           "a \(status) was queued")
        }
    }

    /// No signal is a condition that passes.
    func testEveryNetworkFailureIsQueued() {
        for code: URLError.Code in [.notConnectedToInternet, .timedOut,
                                    .networkConnectionLost, .cannotFindHost,
                                    .dnsLookupFailed, .cannotConnectToHost] {
            XCTAssertTrue(PendingOperations.isWorthRetrying(URLError(code)),
                          "\(code) was not queued")
        }
    }

    /// The server being unwell is not the server disagreeing.
    func testServerErrorsAndBackpressureAreQueued() {
        for status in [500, 502, 503, 504, 408, 429] {
            let error = APIClient.APIError.http(status: status, code: nil, message: nil)
            XCTAssertTrue(PendingOperations.isWorthRetrying(error), "a \(status) was dropped")
        }
    }

    /// NOT queued, and this is the subtle one: if the response failed to
    /// decode, the write very likely SUCCEEDED and only the reply was
    /// unreadable. The key would make a replay safe — but showing a
    /// pending row for work already done is a different lie from the one
    /// this prevents.
    func testADecodeFailureIsNotQueued() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        XCTAssertFalse(PendingOperations.isWorthRetrying(error))
    }

    /// The boundary, asserted rather than assumed: 499 is a refusal and
    /// 500 is not.
    func testTheFourHundredFiveHundredBoundary() {
        XCTAssertFalse(PendingOperations.isWorthRetrying(
            APIClient.APIError.http(status: 499, code: nil, message: nil)))
        XCTAssertTrue(PendingOperations.isWorthRetrying(
            APIClient.APIError.http(status: 500, code: nil, message: nil)))
    }

    /// A 429 is BOTH: still worth retrying — the sheet's «Запази за
    /// по-късно» is offered on it — and a wait, which is what pauses the
    /// queue instead of spending an attempt.
    func testA429IsRetriableAndPausesTheQueue() {
        let error = APIClient.APIError.http(
            status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: 12)
        XCTAssertTrue(PendingOperations.isWorthRetrying(error))
        XCTAssertEqual(RateLimitGate.wait(for: error), .seconds(12))

        // A 503 with the same header stays an ordinary, COUNTED transient.
        let unwell = APIClient.APIError.http(
            status: 503, code: nil, message: nil, retryAfterSeconds: 12)
        XCTAssertTrue(PendingOperations.isWorthRetrying(unwell))
        XCTAssertNil(RateLimitGate.wait(for: unwell))
    }
}

final class PendingOperationTests: XCTestCase {

    private func operation(id: String = UUID().uuidString) -> PendingOperation {
        PendingOperation(
            id: id, locationID: "loc", parcelSummary: "15655-19 · Пръскане",
            payload: Data(#"{"operationType":"SPRAY"}"#.utf8),
            createdAt: Date(), attempts: 0, lastAttemptAt: nil, lastError: nil)
    }

    /// THE ID IS THE IDEMPOTENCY KEY, the file name and the identity, all
    /// three. A queue that minted a separate id would eventually let two
    /// rows carry one key or one row carry two — either of which is how a
    /// duplicate spray reaches a filed register.
    func testTheIDIsAUUIDAndCannotEscapeItsDirectory() {
        let id = operation().id
        XCTAssertNotNil(UUID(uuidString: id), "the id must be a UUID: \(id)")
        XCTAssertFalse(id.contains("/"))
        XCTAssertFalse(id.contains(".."))
    }

    func testItRoundTripsThroughDisk() throws {
        let original = operation()
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(PendingOperation.self, from: data)
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.payload, original.payload, "the recorded bytes changed")
    }

    /// The payload is stored as RAW BYTES, not a re-encoded model, so an
    /// app update that renames a field cannot alter what the farmer
    /// actually wrote down before it is sent.
    func testThePayloadIsBytesAndNotAModel() throws {
        let original = operation()
        let back = try JSONDecoder().decode(
            PendingOperation.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(String(data: back.payload, encoding: .utf8),
                       #"{"operationType":"SPRAY"}"#)
    }

    /// "Not sent yet" and "the server said no" need opposite things from a
    /// person — signal, or attention. Collapsing them would leave a refused
    /// record waiting forever under a label saying it is fine.
    func testRefusedIsDistinctFromWaiting() {
        var op = operation()
        XCTAssertFalse(op.isRefused)
        op.isRefused = true
        op.lastError = "Нямате права за това действие."
        XCTAssertTrue(op.isRefused)
    }

    /// The outbox carries FIELD OPERATIONS and nothing else. This asserts
    /// the app has no way to queue anything else, and the reasons differ per
    /// route — which is why the loop below no longer states one reason for
    /// all of them:
    ///
    ///   - the exchange listing and the inquiry honour no `Idempotency-Key`
    ///     and have no natural key. A replay puts a second offer on a public
    ///     board. They must never be queued, at all.
    ///   - `CostsAPI` is different since 2026-09-25: `POST /grain/costs` DOES
    ///     honour the header and the app sends a key. A replay would be
    ///     deduped correctly, so queueing one is no longer UNSAFE — it is
    ///     merely undecided. That key is minted per draft, and nobody has
    ///     worked out what a queued cost means after the operator has moved
    ///     on and possibly re-entered it by hand. Until someone does, the
    ///     outbox stays out of the books.
    ///   - exchange MESSAGES, once they exist. Their send honours a key, so a
    ///     replay would be safe — and it would still be wrong: a message is a
    ///     deliberate act addressed to somebody, sent at a moment the operator
    ///     chose. Nothing sends one on the app's schedule, not even after a
    ///     429 (`RateLimitPause.messages` has no callback, on purpose). The
    ///     names below are the path builders messaging is expected to add.
    func testOnlyFieldOperationsCanBeQueued() {
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Agrent/Core/OutboxStore.swift"),
            encoding: .utf8)
        let text = try? XCTUnwrap(source)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("operationsPath") == true,
                      "positive control: the outbox posts to the operations path")
        for forbidden in ["listingsPath", "inquiriesPath", "createListing"] {
            XCTAssertFalse(text?.contains(forbidden) == true,
                           "the outbox can replay \(forbidden), which honours no key")
        }
        for forbidden in ["threadsPath", "threadPath", "openThreadPath", "messagesPath",
                          "messagePath", "readPath", "closePath", "blockPath"] {
            XCTAssertFalse(text?.contains(forbidden) == true,
                           "the outbox can send \(forbidden) — a message is never queued")
        }
        XCTAssertFalse(
            text?.contains("CostsAPI") == true,
            "the outbox can replay a grain cost; the route dedupes, but the key is "
                + "minted per draft and queueing one has not been designed")
    }
}

/// Concurrency, because the app fires `flush()` from three places — on
/// launch, on every return to the foreground, and from the banner button.
@MainActor
final class OutboxFlushCoalescingTests: XCTestCase {

    /// THE DEFECT A PROBE FOUND. `flush()` guarded with a plain
    /// `guard !isFlushing else { return }`, which is right for "two
    /// triggers fired at once" and WRONG for "new work arrived mid-drain"
    /// — the second case silently skipped the new item until some later,
    /// unrelated trigger happened to fire.
    ///
    /// Observed: a probe that enqueued and flushed in the same breath saw
    /// `attempts` stay at 0 and no error recorded. The queue looked
    /// healthy and had done nothing.
    func testAConcurrentFlushIsDeferredNotDropped() async {
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Agrent/Core/OutboxStore.swift"),
            encoding: .utf8)
        let text = source ?? ""
        XCTAssertTrue(text.contains("needsAnotherPass"),
                      "positive control: the coalescing flag exists")
        XCTAssertTrue(text.contains("while needsAnotherPass"),
                      "the drain must take another turn, not return")
        XCTAssertFalse(text.contains("guard !isFlushing else { return }"),
                       "a concurrent flush is being dropped again")
    }
}

/// The outbox under a 429 — agrent-ios#112.
///
/// Source checks, in the style of the coalescing test above, because the
/// store is a singleton over the real disk and the real network, and this
/// suite has no seam that answers a POST with a 429. What the checks cannot
/// see — that `absorb` is true for a 429 and for nothing else — is held
/// behaviourally in `RateLimitPauseTests.testOnlyA429ClosesIt`.
@MainActor
final class OutboxRateLimitTests: XCTestCase {

    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/Core/OutboxStore.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A 429 SPENDS NO ATTEMPT and rewrites nothing.
    ///
    /// The whole fix is the ORDER inside the drain's catch: absorbed and out
    /// before the bump, so the item is left exactly as it was. After the bump,
    /// every 429 of a reconnect burst would count against an item the server
    /// never even looked at — harmless only for as long as nothing caps
    /// attempts.
    func testA429SpendsNoAttempt() {
        let text = source
        guard let absorb = text.range(of: "if pause.absorb(error) { break }"),
              let bump = text.range(of: "item.attempts += 1") else {
            return XCTFail("positive control: the absorb and the bump are both in the drain")
        }
        XCTAssertLessThan(absorb.lowerBound, bump.lowerBound,
                          "the attempt is spent before the 429 is absorbed")
        XCTAssertEqual(text.components(separatedBy: "item.attempts += 1").count - 1, 1,
                       "a second place spends attempts")
        XCTAssertEqual(text.components(separatedBy: "pause.absorb(").count - 1, 1,
                       "a second place absorbs, so the one checked may not be the one that runs")
    }

    /// NO SESSION REFUSES NOTHING.
    ///
    /// `notSignedIn` is thrown before a request leaves, so the server never
    /// saw the item, and refused is permanent. The pause's alarm outlives the
    /// signed-in screen, which is what made a drain with no token reachable:
    /// before this stop, signing out inside a pause stamped every queued
    /// spray refused. The stop must come before the bump for the same reason
    /// the 429's does.
    func testNoSessionSpendsNoAttemptAndRefusesNothing() {
        let text = source
        guard let noSession = text.range(
                of: "if case APIClient.APIError.notSignedIn = error { break }"),
              let bump = text.range(of: "item.attempts += 1") else {
            return XCTFail("positive control: the no-session stop and the bump are both in the drain")
        }
        XCTAssertLessThan(noSession.lowerBound, bump.lowerBound,
                          "a drain with no session spends an attempt and refuses the item")

        // Why the drain has to stop on it ITSELF: the retry policy calls it
        // final, and final is what marks an item refused.
        XCTAssertFalse(PendingOperations.isWorthRetrying(APIClient.APIError.notSignedIn))
    }

    /// NOTHING GOES OUT WHILE PAUSED. The pause is checked before anything
    /// else in `flush()`, and the disarm is reached only by a pass that is
    /// really starting — a flush that returns early must not cancel the alarm
    /// that is the queue's only way back. A pause that closes mid-pass ends
    /// the coalescing loop.
    func testAPausedFlushSendsNothingAndReArms() {
        let text = source
        guard let paused = text.range(of: "guard !pause.isPaused else {"),
              let flushing = text.range(of: "guard !isFlushing else {"),
              let disarm = text.range(of: "pause.disarm()"),
              let drain = text.range(of: "await drain()") else {
            return XCTFail("positive control: flush's guards are where this expects them")
        }
        XCTAssertLessThan(paused.lowerBound, flushing.lowerBound,
                          "the coalescing guard runs before the pause is checked")
        XCTAssertLessThan(flushing.lowerBound, disarm.lowerBound,
                          "a flush that returns early can cancel the alarm")
        XCTAssertLessThan(disarm.lowerBound, drain.lowerBound)

        // The paused branch re-arms rather than doing nothing.
        let pausedBranch = text[paused.upperBound...].prefix(60)
        XCTAssertTrue(pausedBranch.contains("pause.arm()"), String(pausedBranch))

        XCTAssertTrue(text.contains("while needsAnotherPass && !pause.isPaused"),
                      "a coalesced pass walks into a pause that closed mid-drain")
    }

    /// The alarm is what wakes the queue: the store wires its drain as the
    /// pause's callback.
    func testTheQueueDrainsWhenThePauseReopens() {
        XCTAssertNotNil(OutboxStore.shared.pause.onReopen)
        XCTAssertTrue(source.contains("pause.onReopen = { [weak self] in await self?.flush() }"))
    }

    private func read(_ path: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// THE SHEET'S 429 IS THE OUTBOX'S 429. The live save posts to the same
    /// route on the same budget, so the error that made the operator queue
    /// the operation closes the outbox's pause — BEFORE the item joins the
    /// queue, or the next foreground flush spends a request on it inside the
    /// window. Deleting that one line fails nothing else in this suite.
    func testTheSheetsRateLimitPausesTheQueueBeforeQueueing() {
        let text = read("Agrent/Locations/ParcelOperationSheet.swift")
        guard let absorb = text.range(of: "OutboxStore.shared.pause.absorb(failureError)"),
              let enqueue = text.range(of: "OutboxStore.shared.enqueue(") else {
            return XCTFail("the sheet no longer hands its failure to the outbox's pause")
        }
        XCTAssertLessThan(absorb.lowerBound, enqueue.lowerBound,
                          "the item joins the queue before the pause closes")
    }

    /// THE BANNER HIDES «Изпрати» WHILE IT SHOWS THE WAIT, and says why.
    ///
    /// A tap inside the pause could only buy a guaranteed 429, and a control
    /// that vanished says nothing to VoiceOver unless the reason is in the
    /// description it sits beside. Source checks, because nothing here
    /// renders the banner: reverting either line fails nothing else.
    func testTheBannerReplacesTheButtonWithTheReason() {
        let text = read("Agrent/Core/OutboxBanner.swift")
        XCTAssertTrue(text.contains("outbox.refused.isEmpty && caption == nil"),
                      "«Изпрати» is shown beside the caption that replaces it")
        guard let sentence = text.range(of: "A11y.sentence(") else {
            return XCTFail("positive control: the banner builds its spoken description")
        }
        let spoken = text[sentence.upperBound...].prefix(120)
        XCTAssertTrue(spoken.contains("caption"),
                      "VoiceOver is not told why there is no «Изпрати»: \(spoken)")
    }
}
