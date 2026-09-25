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
