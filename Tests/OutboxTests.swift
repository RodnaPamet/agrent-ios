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

    /// THE SPRAY SHEET'S OFFER (#169). «Запази за по-късно» on exactly what
    /// the retry policy calls retriable — AND on a 426, which the policy
    /// calls final: the server's version gate turned the BUILD away, not the
    /// record, so the record is kept for the updated app. The web keeps
    /// nothing on a 426; the divergence is the owner's (PARITY.md, Locations).
    func testTheSpraySheetKeepsA426ForTheUpdatedApp() {
        typealias Offer = ParcelOperationSheet.QueueOffer
        XCTAssertEqual(Offer.after(APIClient.APIError.clientTooOld), .afterUpdate)
        // The policy itself is unchanged: retrying from the same build buys
        // the same 426, and the drain and a line's tap rely on it (#168).
        XCTAssertFalse(PendingOperations.isWorthRetrying(APIClient.APIError.clientTooOld))

        // Positive controls: everything else gets the policy's answer, as before.
        let retriable: [Error] = [
            URLError(.notConnectedToInternet), URLError(.timedOut),
            APIClient.APIError.http(status: 503, code: nil, message: nil),
            APIClient.APIError.http(status: 408, code: nil, message: nil),
            APIClient.APIError.http(status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: 12),
        ]
        for error in retriable {
            XCTAssertEqual(Offer.after(error), .retry, "\(error)")
        }
        let refused: [Error] = [
            APIClient.APIError.http(status: 400, code: nil, message: nil),
            APIClient.APIError.http(status: 403, code: nil, message: nil),
            APIClient.APIError.conflict(currentVersion: 5, expectedVersion: 3),
            APIClient.APIError.notSignedIn,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")),
        ]
        for error in refused {
            XCTAssertEqual(Offer.after(error), .notOffered, "\(error)")
        }

        // What each one promises. The 426's names the update, not a
        // connection — signal will not send it — and not «автоматично»,
        // which would promise what only the operator can start.
        XCTAssertNil(Offer.notOffered.caption, "a refusal is offered a queue")
        XCTAssertEqual(Offer.retry.caption,
                       "Записът остава на устройството и се изпраща автоматично, когато има връзка.")
        let update = Offer.afterUpdate.caption ?? ""
        XCTAssertTrue(update.contains("след обновяване на приложението"), update)
        XCTAssertFalse(update.contains("връзка"), update)
        XCTAssertFalse(update.contains("автоматично"), update)
        XCTAssertTrue(update.hasSuffix("."), update)
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

    /// The outbox carries FIELD WORK and nothing else: field-operation
    /// creates, and — since agrent-ios#138, DELIBERATELY — the marks on a
    /// field operation's parcel lines. This asserts the app has no way to
    /// queue anything else, and the reasons differ per route — which is why
    /// the loop below no longer states one reason for all of them.
    ///
    /// ── What #138 added, and why it may be queued ──
    ///
    /// `PATCH /field-operations/{taskId}/parcels/{lineId}` reads no
    /// `Idempotency-Key`, so the licence the create has does not carry over.
    /// Its licence is the optimistic lock instead: the mark replays with
    /// `If-Match: <the version it saw>`, its own lost success comes back 200
    /// `alreadyApplied`, and anybody else's change since comes back 409 — a
    /// CONFLICT the operator resolves, never an overwrite and never a
    /// refusal. The web queues exactly this write for exactly that reason
    /// (`OfflineFieldPanel`, `use-offline-sync.ts:495`). The lock's tests are
    /// in `OutboxLineMarkTests` below.
    ///
    /// The builders the outbox may name are held EXACTLY, so a third write
    /// joining the queue has to come through this test and argue its case
    /// here, as this one did.
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
        XCTAssertTrue(text?.contains("FieldOperationAPI.linePath") == true,
                      "positive control: the outbox replays parcel-line marks (#138)")

        // EXACTLY these two builders, in the code — comments stripped, so a
        // sentence naming a route is not mistaken for a call to it.
        let code = (text ?? "").replacingOccurrences(
            of: #"(?m)(^|\s)//.*$"#, with: "$1", options: .regularExpression)
        let builder = try? NSRegularExpression(pattern: #"\b[A-Z]\w*API\.\w+Path\b"#)
        let named = Set((builder?.matches(in: code, range: NSRange(code.startIndex..., in: code)) ?? [])
            .compactMap { Range($0.range, in: code).map { String(code[$0]) } })
        XCTAssertEqual(named, ["LocationsAPI.operationsPath", "FieldOperationAPI.linePath"],
                       "the outbox can replay a write nobody argued for here")

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

    /// A 426 REFUSES NOTHING (#168).
    ///
    /// The server's version gate answers before any route runs, so a 426 is
    /// about the build and never about the item. The retry policy calls it
    /// final all the same, and a refusal does not stop the pass — which is how
    /// one 426 used to stamp every queued spray and parcel-line mark refused,
    /// permanently, in one pass. The stop must come before the bump for the
    /// reason the 429's and no-session's do. Held at runtime, for both kinds,
    /// in `OutboxLineMarkTests` section 6.
    func testA426SpendsNoAttemptAndRefusesNothing() {
        let text = source
        guard let tooOld = text.range(of: "if absorbClientTooOld(error) { break }"),
              let bump = text.range(of: "item.attempts += 1") else {
            return XCTFail("positive control: the 426 stop and the bump are both in the drain")
        }
        XCTAssertLessThan(tooOld.lowerBound, bump.lowerBound,
                          "a 426 spends an attempt and refuses the item")
        XCTAssertEqual(text.components(separatedBy: "absorbClientTooOld(error)").count - 1, 1,
                       "a second place stops on a 426, so the one checked may not be the one that runs")

        // And no trigger asks again: `flush` refuses to start a pass before it
        // can show a spinner, and a coalesced turn is not taken after one.
        guard let refused = text.range(of: "guard !isClientTooOld else { return }"),
              let flushing = text.range(of: "isFlushing = true") else {
            return XCTFail("positive control: flush's 426 guard and its spinner are where this expects them")
        }
        XCTAssertLessThan(refused.lowerBound, flushing.lowerBound,
                          "a flush after a 426 shows a spinner for a pass it will not make")
        XCTAssertTrue(text.contains("while needsAnotherPass && !pause.isPaused && !isClientTooOld"),
                      "a coalesced pass sends the first item into the same 426 again")

        // Why the drain has to stop on it ITSELF: the retry policy calls it
        // final, and final is what marks an item refused.
        XCTAssertFalse(PendingOperations.isWorthRetrying(APIClient.APIError.clientTooOld))
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

    /// THE SHEET'S 426 IS THE OUTBOX'S 426, told before anything is kept
    /// (#169). The button stands on the decision
    /// `testTheSpraySheetKeepsA426ForTheUpdatedApp` reads, and `save()` tells
    /// the outbox of the 426 before «Запази за по-късно» can even be tapped,
    /// so a record kept on one joins a queue that already waits for the
    /// update — rather than being sent into the same 426 by the next trigger
    /// while the banner still offers «Изпрати». Source checks, because
    /// nothing in this suite renders the sheet; comments are stripped, so a
    /// sentence ABOUT the call is not taken for it.
    func testTheSheetTellsTheOutboxBeforeKeepingA426() {
        let text = SignOutHygieneTests.code(read("Agrent/Locations/ParcelOperationSheet.swift"))
        guard let save = text.range(of: "private func save() async {"),
              let keep = text.range(of: "private func queueForLater() async {") else {
            return XCTFail("positive control: the sheet's save and its queueing are where this expects them")
        }
        let saving = text[save.upperBound..<keep.lowerBound]
        XCTAssertTrue(saving.contains("queueOffer = QueueOffer.after(error)"),
                      "the offer is decided by something no test reads")
        XCTAssertTrue(saving.contains("OutboxStore.shared.absorbClientTooOld(error)"),
                      "the outbox learns of the 426 only by sending the kept record into it")
        XCTAssertTrue(text.contains("if let promise = queueOffer.caption {"),
                      "the button is shown on something other than the decision")
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

        // The caption shown, and the one announced after «Изпрати», is what
        // `OutboxBanner.caption(for:)` returns — the function the runtime
        // test of the banner reads (`OutboxLineMarkTests`, section 6). Twice:
        // the render and the announcement.
        XCTAssertTrue(text.contains("let caption = Self.caption(for: outbox)"),
                      "the banner renders a caption no test reads")
        XCTAssertEqual(text.components(separatedBy: "Self.caption(for: outbox)").count - 1, 2,
                       "the banner shows or announces a caption no test reads")
    }
}

/// The outbox's second kind: a parcel-line MARK (agrent-ios#138).
///
/// Run for real — a real `OutboxStore` over a `PendingOperations` directory of
/// its own, with a sender that records and answers as told. Nothing reaches
/// the network: the sender is a closure, and the one call that would
/// (`OutboxStore.post`) is driven only with a row it refuses before sending.
///
/// The claims, each a way the lock could be on the wire and protect nothing:
///   1. a queued mark carries the version it SAW, on disk and on replay;
///   2. a replay is a PATCH with that version as a bare `If-Match`, no key;
///   3. a stale replay (409) is a CONFLICT — parked, never refused, never
///      resent by a pass, resolved only by the operator;
///   4. the queue keeps its other rules for marks: whose, 429, attempts;
///   5. rows written before #138 still read, as creates;
///   6. a 426 is about the BUILD (#168): it leaves every row of both kinds
///      exactly as it was, stops the pass, and nothing asks again — and the
///      banner says why;
///   7. a spray the sheet KEEPS on a 426 (#169) stays parked for the rest of
///      the process, and the updated app sends it.
@MainActor
final class OutboxLineMarkTests: XCTestCase {

    private let owner = "usr-a-0001"
    private let other = "usr-b-0002"

    /// Directories made by this suite, removed after each test.
    private var directories: [String] = []

    override func tearDown() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in directories {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        directories = []
    }

    private func makeQueue() -> PendingOperations {
        let name = "OutboxLineMark-\(UUID().uuidString)"
        directories.append(name)
        return PendingOperations(directoryName: name)
    }

    /// What the drain sent, and how each send is answered.
    private final class Wire {
        var sent: [PendingOperation] = []
        var answer: (PendingOperation) async throws -> Void = { _ in }
    }

    /// Who is signed in, as a variable.
    private final class Identity {
        var id: String?
        init(_ id: String?) { self.id = id }
    }

    private func makeOutbox(_ queue: PendingOperations, _ wire: Wire, _ identity: Identity) -> OutboxStore {
        OutboxStore(
            queue: queue,
            currentOwner: { identity.id },
            identify: {},
            send: { item in
                wire.sent.append(item)
                try await wire.answer(item)
            }
        )
    }

    /// Strictly increasing `createdAt`, so "oldest first" is the order made.
    private var clock = Date(timeIntervalSince1970: 1_900_000_000)

    private func mark(
        line: String = "opl_1", status: OperationLineStatus = .done, seen: Int = 3,
        owner: String? = nil, task: String = "tsk_1"
    ) -> PendingOperation {
        clock.addTimeInterval(1)
        return .mark(
            PendingOperation.LineMark(taskID: task, lineID: line, status: status.rawValue, seenVersion: seen),
            ownerUserID: owner ?? self.owner,
            summary: "FT-1 · SYNTH-1 · \(status.label)",
            payload: Data(#"{"status":"\#(status.rawValue)"}"#.utf8),
            reason: nil, at: clock)
    }

    private func create() -> PendingOperation {
        clock.addTimeInterval(1)
        return PendingOperation(
            id: UUID().uuidString, locationID: "loc", ownerUserID: owner,
            parcelSummary: "SYNTH-1 · Пръскане", payload: Data(#"{"operationType":"SPRAY"}"#.utf8),
            createdAt: clock, attempts: 0, lastAttemptAt: nil, lastError: nil)
    }

    /// 409 STALE_DATA as `APIClient` throws it: the server holds version 5,
    /// the mark asserted 3.
    private let stale = APIClient.APIError.conflict(currentVersion: 5, expectedVersion: 3)

    // MARK: - 1. The version it saw

    func testAMarkKeepsTheVersionItSawThroughTheDisk() async throws {
        let item = mark(seen: 7)
        let back = try JSONDecoder().decode(PendingOperation.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
        XCTAssertEqual(back.lineMark?.seenVersion, 7)
        XCTAssertEqual(back.lineMark?.lineStatus, .done)
        XCTAssertNil(back.locationID, "a mark has no location; its path is the task and the line")
        XCTAssertEqual(back.ownerUserID, owner, "a queued mark is stamped with who made it")

        let queue = makeQueue()
        await queue.enqueue(item)
        let stored = await queue.all()
        XCTAssertEqual(stored.map(\.lineMark?.seenVersion), [7])
        XCTAssertEqual(String(data: stored[0].payload, encoding: .utf8), #"{"status":"DONE"}"#,
                       "the bytes the tap produced are what is replayed")
    }

    // MARK: - 2. The replay

    /// A PATCH to the line, guarded by the version SEEN — and no key, since
    /// the route reads none (`APIClient.patchRaw` sends `nil`).
    func testAMarkReplaysAsAPatchGuardedByTheVersionItSaw() {
        let item = mark(line: "opl_9", seen: 4, task: "tsk_7")
        XCTAssertEqual(
            OutboxStore.replay(for: item),
            .mark(path: FieldOperationAPI.linePath(taskID: "tsk_7", lineID: "opl_9"), seenVersion: 4))
        // The header value that version becomes: the BARE integer.
        XCTAssertEqual(APIClient.ifMatch(4), "4")
    }

    /// The create's replay is what it always was: a POST with its own id as
    /// the key. Positive control for the switch above.
    func testACreateStillReplaysAsAKeyedPost() {
        let item = create()
        XCTAssertEqual(OutboxStore.replay(for: item),
                       .create(path: LocationsAPI.operationsPath("loc"), idempotencyKey: item.id))
    }

    /// A row with neither a location nor a line is refused, not guessed at —
    /// and refused BEFORE anything is sent.
    func testARowWithNoDestinationIsRefusedNotGuessed() async {
        clock.addTimeInterval(1)
        let broken = PendingOperation(
            id: UUID().uuidString, locationID: nil, ownerUserID: owner, parcelSummary: "?",
            payload: Data(), createdAt: clock, attempts: 0, lastAttemptAt: nil, lastError: nil)
        XCTAssertNil(broken.target)
        XCTAssertNil(OutboxStore.replay(for: broken))
        do {
            try await OutboxStore.post(broken)
            XCTFail("a row with no destination was sent somewhere")
        } catch {
            XCTAssertTrue(error is OutboxStore.Unsendable, "\(error)")
        }
        XCTAssertFalse(PendingOperations.isWorthRetrying(OutboxStore.Unsendable()),
                       "it would sit in the queue forever, retried")
    }

    // MARK: - 3. The 409

    /// THE REQUIREMENT (#138): a stale replay is surfaced as a conflict, not
    /// parked as refused — and a pass never sends it again.
    func testAStaleReplayIsParkedAsAConflictNeverAsRefused() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        wire.answer = { _ in throw self.stale }
        let item = mark()
        await outbox.enqueueMark(item)
        await outbox.flush()

        let parked = await queue.all()
        XCTAssertEqual(parked.map(\.id), [item.id], "the mark was dropped")
        XCTAssertEqual(parked.first?.conflict?.currentVersion, 5, "read from error.details, not lost")
        XCTAssertEqual(parked.first?.isRefused, false, "a conflict was stamped refused")
        XCTAssertEqual(parked.first?.attempts, 1, "the server answered it, so it was an attempt")
        XCTAssertEqual(parked.first?.lineMark?.seenVersion, 3, "the version it saw was rewritten")
        XCTAssertEqual(outbox.conflicts.map(\.id), [item.id])
        XCTAssertTrue(outbox.refused.isEmpty, "the banner would call it refused")
        XCTAssertTrue(outbox.sendable.isEmpty, "the banner would call it waiting")

        wire.sent = []
        await outbox.flush()
        XCTAssertTrue(wire.sent.isEmpty, "a parked conflict was resent by a pass")
    }

    /// A conflict is THIS row's, like a refusal: the pass goes on.
    func testThePassGoesOnPastAConflict() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let first = mark(line: "opl_1"), second = mark(line: "opl_2")
        wire.answer = { item in if item.id == first.id { throw self.stale } }
        await outbox.enqueueMark(first)
        await outbox.enqueueMark(second)
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [first.id, second.id])
        let left = await queue.all()
        XCTAssertEqual(left.map(\.id), [first.id], "the second mark did not land, or the first vanished")
    }

    /// A create that meets 409 is what it always was: refused. Only a MARK
    /// has a lock to be in conflict with.
    func testA409OnACreateIsStillARefusal() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        wire.answer = { _ in throw self.stale }
        await outbox.enqueue(create())
        await outbox.flush()
        let stored = await queue.all()
        XCTAssertEqual(stored.first?.isRefused, true)
        XCTAssertNil(stored.first?.conflict)
    }

    /// «Запази моята»: re-queued at the server's version, and sent.
    func testKeepMineResendsAtTheVersionTheServerReported() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        var calls = 0
        wire.answer = { _ in
            calls += 1
            if calls == 1 { throw self.stale }
        }
        let item = mark(seen: 3)
        await outbox.enqueueMark(item)
        await outbox.flush()
        XCTAssertEqual(outbox.conflicts.count, 1, "positive control: it is parked")

        await outbox.keepMine(item.id)
        XCTAssertEqual(wire.sent.map { $0.lineMark?.seenVersion }, [3, 5],
                       "keep-mine did not re-send at the server's version")
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "the accepted mark is still queued")
    }

    /// The line moved AGAIN between the conflict and the choice: the re-send
    /// meets a newer 409 and parks with THAT version — a third person's
    /// change is not overwritten by a decision about the second's.
    func testKeepMineThatMeetsANewerChangeParksAgain() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        var answers: [Error] = [stale, APIClient.APIError.conflict(currentVersion: 8, expectedVersion: 5)]
        wire.answer = { _ in if !answers.isEmpty { throw answers.removeFirst() } }
        let item = mark(seen: 3)
        await outbox.enqueueMark(item)
        await outbox.flush()
        await outbox.keepMine(item.id)
        let parked = await queue.all()
        XCTAssertEqual(parked.first?.conflict?.currentVersion, 8)
        XCTAssertEqual(parked.first?.lineMark?.seenVersion, 5)
        XCTAssertEqual(outbox.conflicts.count, 1)
    }

    /// No version in the 409, no «Запази моята»: re-sending without one is
    /// the unguarded overwrite, and with the old one only the same 409.
    func testKeepMineWithoutAReportedVersionSendsNothing() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        wire.answer = { _ in throw APIClient.APIError.conflict(currentVersion: nil, expectedVersion: 3) }
        let item = mark()
        await outbox.enqueueMark(item)
        await outbox.flush()
        await outbox.keepMine(item.id)
        XCTAssertEqual(wire.sent.count, 1, "keep-mine sent a mark it could not guard")
        XCTAssertEqual(outbox.conflicts.map(\.id), [item.id])
    }

    /// «Използвай сървъра» discards a CONFLICT and nothing else — it must
    /// never become a way to delete a mark that could still be sent.
    func testTakeServerDiscardsAConflictAndNothingElse() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let waiting = mark(line: "opl_2")
        await outbox.enqueueMark(waiting)
        await outbox.takeServer(waiting.id)
        let afterWaiting = await queue.all()
        XCTAssertEqual(afterWaiting.map(\.id), [waiting.id], "a waiting mark was discarded")

        wire.answer = { _ in throw self.stale }
        let conflicted = mark(line: "opl_1")
        await outbox.enqueueMark(conflicted)
        await outbox.flush()
        await outbox.takeServer(conflicted.id)
        let afterConflict = await queue.all()
        XCTAssertFalse(afterConflict.map(\.id).contains(conflicted.id), "the conflict was not discarded")
    }

    // MARK: - Replacing an unsent mark (the web's #934)

    /// The newest mark for a line is the whole intent, so it replaces the
    /// unsent one — and keeps asserting the version the SERVER holds.
    func testANewerMarkReplacesTheUnsentOneForItsLine() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let done = mark(line: "opl_1", status: .done, seen: 3)
        let elsewhere = mark(line: "opl_2", status: .done, seen: 1)
        await outbox.enqueueMark(done)
        await outbox.enqueueMark(elsewhere)
        let reopen = mark(line: "opl_1", status: .pending, seen: 3)
        await outbox.enqueueMark(reopen)

        let stored = await queue.all()
        XCTAssertEqual(stored.map(\.id), [elsewhere.id, reopen.id],
                       "two marks queued for one line would land the DONE and its stock deduction first")
        XCTAssertEqual(stored.last?.lineMark?.seenVersion, 3, "the version was bumped on the phone")
    }

    /// What replacing never touches: a conflict (a decision pending), a
    /// refusal (a record), another person's mark (not theirs to replace).
    func testReplacingNeverTouchesAConflictARefusalOrSomeoneElsesMark() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        var conflicted = mark(line: "opl_1")
        conflicted.conflict = PendingOperation.Conflict(currentVersion: 5, at: clock)
        var refused = mark(line: "opl_1")
        refused.isRefused = true
        refused.attempts = 1
        refused.lastError = "Нямате права за това действие."
        let theirs = mark(line: "opl_1", owner: other)
        for item in [conflicted, refused, theirs] { await queue.enqueue(item) }

        let newer = mark(line: "opl_1", status: .skipped)
        await outbox.enqueueMark(newer)
        let stored = Set(await queue.all().map(\.id))
        XCTAssertEqual(stored, [conflicted.id, refused.id, theirs.id, newer.id])
    }

    /// THE RESURRECTION GUARD. A mark replaced while its own send is in the
    /// air must not be written back when that send fails.
    func testAMarkReplacedMidSendIsNotWrittenBack() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let item = mark()
        await outbox.enqueueMark(item)
        wire.answer = { sent in
            // The operator taps again while this one is in flight.
            await queue.remove(sent.id)
            throw URLError(.notConnectedToInternet)
        }
        await outbox.flush()
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "a replaced mark came back to replay over the newer one")
    }

    /// A row replaced AFTER the pass listed it is not sent from that list.
    /// The operator re-marks line 2 while line 1's mark is in the air; the
    /// pass must not then land line 2's OLD mark — a «Готово», with its stock
    /// deduction, that they had just taken back.
    func testAMarkReplacedAfterThePassBeganIsNotSentFromItsList() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let first = mark(line: "opl_1"), second = mark(line: "opl_2", status: .done)
        let replacement = mark(line: "opl_2", status: .pending)
        await outbox.enqueueMark(first)
        await outbox.enqueueMark(second)
        wire.answer = { sent in
            if sent.id == first.id { await outbox.enqueueMark(replacement) }
        }
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [first.id], "the replaced mark went out from the pass's old list")
        let left = await queue.all()
        XCTAssertEqual(left.map(\.id), [replacement.id], "the newer mark is not waiting for the next pass")
    }

    /// «Запази моята» is decided on the row as it is on DISK, not on the
    /// screen's copy: a conflict already resolved in between is left alone.
    func testKeepMineActsOnTheRowOnDiskNotTheScreensCopy() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        var conflicted = mark()
        conflicted.conflict = PendingOperation.Conflict(currentVersion: 5, at: clock)
        await queue.enqueue(conflicted)
        await outbox.refresh()
        XCTAssertEqual(outbox.conflicts.map(\.id), [conflicted.id], "positive control: the screen sees it")

        // Resolved behind the screen's back — another tap's «Използвай сървъра».
        await queue.remove(conflicted.id)
        await outbox.keepMine(conflicted.id)
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "a stale copy of the conflict was written back")
        XCTAssertTrue(wire.sent.isEmpty)
    }

    /// Positive control for the guard: with nothing removing it, the same
    /// failure keeps the mark, one attempt spent.
    func testAMarkThatMeetsNoSignalStaysQueuedAndStopsThePass() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let first = mark(line: "opl_1"), second = mark(line: "opl_2")
        wire.answer = { _ in throw URLError(.notConnectedToInternet) }
        await outbox.enqueueMark(first)
        await outbox.enqueueMark(second)
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [first.id], "with no signal the pass went on")
        let stored = await queue.all()
        XCTAssertEqual(stored.map(\.attempts), [1, 0])
        XCTAssertTrue(stored.allSatisfy(\.awaitsSend))
        XCTAssertEqual(stored.first?.lineMark?.seenVersion, 3)
    }

    // MARK: - 4. The queue's other rules hold for marks

    /// A 429 spends no attempt and rewrites nothing (#116); the queue waits.
    func testA429OnAMarkSpendsNoAttemptAndPausesTheQueue() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        defer { outbox.pause.reset() }
        wire.answer = { _ in
            throw APIClient.APIError.http(status: 429, code: "RATE_LIMITED", message: nil,
                                          retryAfterSeconds: 30)
        }
        await outbox.enqueueMark(mark())
        await outbox.flush()
        let stored = await queue.all()
        XCTAssertEqual(stored.first?.attempts, 0)
        XCTAssertNil(stored.first?.lastError)
        XCTAssertNil(stored.first?.conflict)
        XCTAssertTrue(outbox.pause.isPaused)
    }

    /// PARKED PER OWNER (#142): B sees none of A's marks, sends none, cannot
    /// resolve A's conflict, and B's own mark on the same line replaces
    /// nothing of A's. A's come back when A does.
    func testAnotherPersonsMarksAreParkedNotSentNotResolvedNotReplaced() async {
        let queue = makeQueue(), wire = Wire(), identity = Identity(owner)
        let outbox = makeOutbox(queue, wire, identity)
        let aWaiting = mark(line: "opl_1")
        var aConflict = mark(line: "opl_2")
        aConflict.conflict = PendingOperation.Conflict(currentVersion: 5, at: clock)
        await queue.enqueue(aWaiting)
        await queue.enqueue(aConflict)

        identity.id = other
        await outbox.refresh()
        XCTAssertTrue(outbox.pending.isEmpty, "B's screen shows A's marks")
        await outbox.flush()
        XCTAssertTrue(wire.sent.isEmpty, "A's mark went out under B's session")
        await outbox.keepMine(aConflict.id)
        await outbox.takeServer(aConflict.id)
        let bMark = mark(line: "opl_1", owner: other)
        await outbox.enqueueMark(bMark)
        let stored = await queue.all()
        XCTAssertEqual(Set(stored.map(\.id)), [aWaiting.id, aConflict.id, bMark.id])
        XCTAssertNotNil(stored.first { $0.id == aConflict.id }?.conflict, "B resolved A's conflict")

        identity.id = owner
        await outbox.refresh()
        XCTAssertEqual(Set(outbox.pending.map(\.id)), [aWaiting.id, aConflict.id])
    }

    // MARK: - 5. Rows from before #138

    /// A row as the build before #138 wrote it — no `lineMark`, no
    /// `conflict` — still reads, as the create it is. Built by hand rather
    /// than by encoding today's type, so a renamed key would fail here.
    func testARowWrittenBeforeLineMarksStillReadsAsACreate() throws {
        let payload = Data(#"{"operationType":"SPRAY"}"#.utf8).base64EncodedString()
        let id = UUID().uuidString
        let old = """
        {"id":"\(id)","locationID":"loc_old","ownerUserID":"\(owner)",
         "parcelSummary":"SYNTH-1 · Пръскане","payload":"\(payload)",
         "createdAt":781000000,"attempts":2,"lastAttemptAt":781000100,
         "lastError":"Няма интернет връзка.","isRefused":false}
        """
        XCTAssertFalse(old.contains("lineMark") || old.contains("conflict"),
                       "positive control: this is the old shape")
        let row = try JSONDecoder().decode(PendingOperation.self, from: Data(old.utf8))
        XCTAssertEqual(row.target, .create(locationID: "loc_old"))
        XCTAssertNil(row.lineMark)
        XCTAssertNil(row.conflict)
        XCTAssertTrue(row.awaitsSend, "an old waiting row stopped being sent")
        XCTAssertEqual(row.attempts, 2)
        XCTAssertEqual(OutboxStore.replay(for: row),
                       .create(path: LocationsAPI.operationsPath("loc_old"), idempotencyKey: id))
    }

    /// And through the real queue: `all()` swallows a row it cannot decode,
    /// so a failure here would be a spray silently vanishing.
    func testTheQueueStillListsARowFromBeforeLineMarks() async throws {
        let queue = makeQueue()
        let legacy = create()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "lineMark")
        json.removeValue(forKey: "conflict")
        await queue.enqueue(legacy)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = try XCTUnwrap(directories.last)
        let file = support.appendingPathComponent(directory).appendingPathComponent(legacy.id)
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let rows = await queue.all()
        XCTAssertEqual(rows.map(\.id), [legacy.id])
        XCTAssertEqual(rows.first?.target, .create(locationID: "loc"))
    }

    // MARK: - 6. A 426 is about the build (#168)

    /// THE BUG (#168). A 426 met mid-queue stamped its row REFUSED, and a
    /// refusal does not stop the pass, so every row behind it — sprays and
    /// marks alike — was refused in the same pass: permanently, never to be
    /// sent even by the updated app. The server's version gate answers before
    /// any route runs, so the answer is about the BUILD: every row stays
    /// exactly as it was, and the pass stops at the first one to meet it.
    ///
    /// Run with a create and then a mark meeting the 426 first. Their
    /// replays are different requests (a keyed POST, a guarded PATCH), and
    /// only a mark's failure is ever read for a conflict.
    func testA426MidQueueLeavesEveryRowOfBothKindsUntouchedAndStopsThePass() async {
        for markFirst in [false, true] {
            let kind = markFirst ? "a mark" : "a create"
            let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
            let landed = create()
            let rows = markFirst
                ? [mark(line: "opl_1"), create(), mark(line: "opl_2"), create()]
                : [create(), mark(line: "opl_1"), create(), mark(line: "opl_2")]
            for item in [landed] + rows { await queue.enqueue(item) }
            let before = await queue.all()
            XCTAssertEqual(before.map(\.id), ([landed] + rows).map(\.id), "positive control: oldest first")
            wire.answer = { item in
                // The first lands; from the next on, the server turns the build away.
                if item.id != landed.id { throw APIClient.APIError.clientTooOld }
            }

            await outbox.flush()

            XCTAssertEqual(wire.sent.map(\.id), [landed.id, rows[0].id],
                           "the pass went on past \(kind)'s 426")
            let after = await queue.all()
            XCTAssertEqual(after, Array(before.dropFirst()), "a 426 on \(kind) touched a row on disk")
            for row in after {
                XCTAssertEqual(row.attempts, 0, "an attempt was spent (\(kind))")
                XCTAssertNil(row.lastError, "an error was written (\(kind))")
                XCTAssertFalse(row.isRefused, "refused — never to be sent, even once updated (\(kind))")
                XCTAssertNil(row.conflict, "parked for a decision nobody has to make (\(kind))")
            }
            XCTAssertTrue(outbox.refused.isEmpty, "the banner would say the server declined them")
            XCTAssertEqual(outbox.sendable.map(\.id), rows.map(\.id))
            XCTAssertTrue(outbox.isClientTooOld)
            XCTAssertFalse(outbox.pause.isPaused, "a 426 closed the 429's pause")
        }
    }

    /// Positive control for the test above: the same kinds meeting a REAL
    /// refusal — a 400, about the payload — are refused row by row while the
    /// pass goes on, so its assertions can see a refusal when there is one.
    func testA400OnTheSameKindsIsRefusedRowByRow() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let rows = [create(), mark(line: "opl_1")]
        for item in rows { await queue.enqueue(item) }
        wire.answer = { _ in throw APIClient.APIError.http(status: 400, code: nil, message: nil) }
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), rows.map(\.id), "a refusal stopped the pass")
        XCTAssertEqual(outbox.refused.map(\.id), rows.map(\.id))
        XCTAssertFalse(outbox.isClientTooOld, "a 400 was taken for a retired build")
    }

    /// REMEMBERED. Launch, the return to the foreground, «Изпрати» and the
    /// pause's alarm all come through `flush()`, and after a 426 none of them
    /// asks again — not with new work queued since, not after an Изход, not
    /// even of a server that would now say yes. A new process — the updated
    /// app — asks once more, and the queue goes out as it stood.
    func testAfterA426NothingAsksAgainUntilARelaunch() async {
        let queue = makeQueue(), wire = Wire(), identity = Identity(owner)
        let outbox = makeOutbox(queue, wire, identity)
        let spray = create()
        await outbox.enqueue(spray)
        wire.answer = { _ in throw APIClient.APIError.clientTooOld }
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [spray.id], "positive control: the 426 was met")

        wire.answer = { _ in }
        let later = mark(line: "opl_5")
        await outbox.enqueueMark(later)
        await outbox.flush()
        XCTAssertEqual(wire.sent.count, 1, "a trigger asked the server again")
        XCTAssertFalse(outbox.isFlushing)

        // An Изход and the next sign-in run the same build.
        outbox.reset()
        XCTAssertTrue(outbox.isClientTooOld, "an Изход forgot what the server said about the build")
        await outbox.flush()
        XCTAssertEqual(wire.sent.count, 1)

        // Not even who is signed in. With nobody known a pass begins by
        // asking `/me` — a request that would get the same 426.
        var asked = 0
        let nobodyKnown = OutboxStore(queue: makeQueue(), currentOwner: { nil },
                                      identify: { asked += 1 }, send: { _ in })
        await nobodyKnown.flush()
        XCTAssertEqual(asked, 1, "positive control: a pass with nobody known asks who it is")
        nobodyKnown.absorbClientTooOld(APIClient.APIError.clientTooOld)
        await nobodyKnown.flush()
        XCTAssertEqual(asked, 1, "a pass after a 426 asked the server who is signed in")

        let relaunched = makeOutbox(queue, wire, identity)
        XCTAssertFalse(relaunched.isClientTooOld)
        await relaunched.flush()
        XCTAssertEqual(wire.sent.dropFirst().map(\.id), [spray.id, later.id],
                       "the queue did not go out from the updated app")
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty)
    }

    /// «Запази моята» re-sends through the drain, so it can meet a 426 there.
    /// The decision stands: re-queued at the server's version and waiting —
    /// not refused, not parked again — for the updated app to send.
    func testKeepMineThatMeetsA426WaitsForTheUpdate() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        var answers: [Error] = [stale, APIClient.APIError.clientTooOld]
        wire.answer = { _ in if !answers.isEmpty { throw answers.removeFirst() } }
        let item = mark(seen: 3)
        await outbox.enqueueMark(item)
        await outbox.flush()
        XCTAssertEqual(outbox.conflicts.map(\.id), [item.id], "positive control: it is parked")

        await outbox.keepMine(item.id)
        XCTAssertEqual(wire.sent.map { $0.lineMark?.seenVersion }, [3, 5], "keep-mine was not re-sent")
        let stored = await queue.all()
        XCTAssertEqual(stored.map(\.id), [item.id], "the decision was lost")
        XCTAssertNil(stored.first?.conflict, "a 426 parked the decision again")
        XCTAssertEqual(stored.first?.lineMark?.seenVersion, 5, "the decision was undone")
        XCTAssertEqual(stored.first?.isRefused, false)
        XCTAssertEqual(stored.first?.attempts, 1, "the 426 spent an attempt; only the 409 may")
        XCTAssertEqual(outbox.sendable.map(\.id), [item.id])
        XCTAssertTrue(outbox.isClientTooOld)
    }

    /// Work queued DURING the pass that met the 426 gets no second turn: it
    /// would be the same answer.
    func testWorkQueuedDuringThePassThatMetA426IsNotSent() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let first = create(), later = mark(line: "opl_3")
        await queue.enqueue(first)
        wire.answer = { _ in
            // A tap queues a mark, and a trigger fires while this is in the air.
            await outbox.enqueueMark(later)
            await outbox.flush()
            throw APIClient.APIError.clientTooOld
        }
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [first.id], "another turn sent into the same 426")
        let stored = await queue.all()
        XCTAssertEqual(stored.map(\.id), [first.id, later.id])
        XCTAssertTrue(stored.allSatisfy { $0.attempts == 0 && !$0.isRefused })
    }

    /// A live write that meets a 426 while a pass runs — the spray sheet's
    /// save, a line's tap — stops the pass before its next row.
    func testA426LearnedByALiveWriteStopsAPassUnderWay() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        let first = create(), second = mark(line: "opl_1")
        await queue.enqueue(first)
        await queue.enqueue(second)
        wire.answer = { sent in
            // The sheet's save meets a 426 while this row is in the air; the row lands.
            if sent.id == first.id { outbox.absorbClientTooOld(APIClient.APIError.clientTooOld) }
        }
        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [first.id], "the next row went out into the same 426")
        let left = await queue.all()
        XCTAssertEqual(left.map(\.id), [second.id])
        XCTAssertEqual(left.first?.attempts, 0)
    }

    /// THE BANNER. Once a 426 is known, the line saying the build is too old
    /// — and that nothing is lost — stands where «Изпрати» was; also over a
    /// pause, whose promised resumption would send nothing. Only while
    /// something waits to be SENT: a lone conflict waits for the operator.
    /// (That the banner shows and speaks this caption: the source check in
    /// `OutboxRateLimitTests.testTheBannerReplacesTheButtonWithTheReason`.)
    func testTheBannerSaysTheBuildIsTooOldInPlaceOfSend() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire, Identity(owner))
        defer { outbox.pause.reset() }
        await outbox.enqueueMark(mark())
        XCTAssertNil(OutboxBanner.caption(for: outbox), "positive control: «Изпрати» is offered")

        wire.answer = { _ in throw APIClient.APIError.clientTooOld }
        await outbox.flush()
        XCTAssertEqual(OutboxBanner.caption(for: outbox), UserMessage.outboxClientTooOld)

        outbox.pause.absorb(APIClient.APIError.http(
            status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: 30))
        XCTAssertTrue(outbox.pause.isPaused, "positive control: the pause closed")
        XCTAssertEqual(OutboxBanner.caption(for: outbox), UserMessage.outboxClientTooOld,
                       "the pause's line promises a resumption that will send nothing")

        let parkedQueue = makeQueue()
        let onlyAConflict = makeOutbox(parkedQueue, Wire(), Identity(owner))
        var conflicted = mark(line: "opl_8")
        conflicted.conflict = PendingOperation.Conflict(currentVersion: 5, at: clock)
        await parkedQueue.enqueue(conflicted)
        await onlyAConflict.refresh()
        onlyAConflict.absorbClientTooOld(APIClient.APIError.clientTooOld)
        XCTAssertNil(OutboxBanner.caption(for: onlyAConflict),
                     "a lone conflict waits for the operator's choice, not for the update")

        // The words: what happened, that nothing is lost, and what sends it.
        let line = UserMessage.outboxClientTooOld
        XCTAssertTrue(line.hasPrefix("Тази версия на приложението е остаряла."), line)
        XCTAssertTrue(line.contains("запазени на телефона"), line)
        XCTAssertTrue(line.contains("след обновяване"), line)
        XCTAssertFalse(line.contains("автоматично"), "only an update sends them: \(line)")
        XCTAssertTrue(line.hasSuffix("."), line)
    }

    // MARK: - 7. A spray kept on a 426 (#169)

    /// THE OWNER'S CALL (#169). The spray sheet's live save meets a 426 and
    /// tells the outbox, as `save()` does; the operator taps «Запази за
    /// по-късно», and the record is queued the way `queueForLater()` queues
    /// it — the save's key as its id, its owner, the 426's sentence as its
    /// last error, no attempt spent.
    ///
    /// It must then stay PARKED. Launch, the foreground, «Изпрати» and the
    /// pause's alarm all come through `flush()`, and none of them may send it
    /// from the build the server retired, or call it refused; the banner says
    /// it waits for the update. A new process — the updated app — sends it
    /// once, as the keyed POST the live save was.
    func testASprayKeptOnA426StaysParkedUntilTheUpdatedAppSendsIt() async {
        let queue = makeQueue(), wire = Wire(), identity = Identity(owner)
        let outbox = makeOutbox(queue, wire, identity)
        let refusal = APIClient.APIError.clientTooOld
        XCTAssertEqual(ParcelOperationSheet.QueueOffer.after(refusal), .afterUpdate,
                       "positive control: the sheet offers to keep it")

        // `save()`: the live answer is the outbox's answer too.
        outbox.absorbClientTooOld(refusal)
        // `queueForLater()`: its 429 line is a no-op for a 426, and the row is
        // the one the sheet writes.
        outbox.pause.absorb(refusal)
        clock.addTimeInterval(1)
        let key = UUID().uuidString
        await outbox.enqueue(PendingOperation(
            id: key, locationID: "loc", ownerUserID: owner,
            parcelSummary: "SYNTH-1 · Пръскане", payload: Data(#"{"operationType":"SPRAY"}"#.utf8),
            createdAt: clock, attempts: 0, lastAttemptAt: nil,
            lastError: UserMessage.text(for: refusal)))
        let kept = await queue.all()
        XCTAssertEqual(kept.map(\.id), [key], "positive control: the record is on the phone")
        XCTAssertFalse(outbox.pause.isPaused, "a 426 closed the 429's pause")

        // Every trigger, more than once.
        for _ in 0..<3 { await outbox.flush() }
        XCTAssertTrue(wire.sent.isEmpty, "a record kept on a 426 went out from the retired build")
        let parked = await queue.all()
        XCTAssertEqual(parked, kept, "the kept record changed on disk")
        XCTAssertEqual(outbox.sendable.map(\.id), [key], "the kept record is not waiting to be sent")
        XCTAssertTrue(outbox.refused.isEmpty, "the kept record reads as refused")
        XCTAssertEqual(OutboxBanner.caption(for: outbox), UserMessage.outboxClientTooOld,
                       "the banner offers «Изпрати» for the same 426")

        // The updated app: a new process, so no flag — and the record goes
        // out once, as the live save's keyed POST.
        let updated = makeOutbox(queue, wire, identity)
        XCTAssertFalse(updated.isClientTooOld, "positive control: the flag does not outlive the process")
        await updated.flush()
        XCTAssertEqual(wire.sent.map(\.id), [key], "the updated app did not send the kept record")
        XCTAssertEqual(wire.sent.first.flatMap(OutboxStore.replay(for:)),
                       .create(path: LocationsAPI.operationsPath("loc"), idempotencyKey: key),
                       "the replay is not the live save's keyed POST")
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "the sent record is still queued")
    }
}
