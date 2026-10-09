import XCTest
@testable import Agrent

/// `IdempotentRetry` (#232): which failures earn another attempt, how long
/// it waits, and when it stops. The sleep is a seam, so nothing here waits.
@MainActor
final class IdempotentRetryTests: XCTestCase {

    private struct Fails: Error {}

    private func http(_ status: Int, retryAfter: Int? = nil) -> Error {
        APIClient.APIError.http(status: status, code: nil, message: nil, retryAfterSeconds: retryAfter)
    }

    /// No signal twice, then through: three attempts, one and three seconds
    /// apart, and the answer of the third.
    func testNoSignalIsTriedAgainUntilItLands() async throws {
        var attempts = 0
        var slept: [Duration] = []
        let answer = try await IdempotentRetry.run(sleep: { slept.append($0) }) {
            attempts += 1
            if attempts < 3 { throw URLError(.notConnectedToInternet) }
            return "landed"
        }
        XCTAssertEqual(answer, "landed")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(slept, [.seconds(1), .seconds(3)])
    }

    /// A refusal is a refusal on the next try too: one attempt, no wait.
    func testARefusalIsNotRetried() async {
        var attempts = 0
        var slept: [Duration] = []
        do {
            _ = try await IdempotentRetry.run(sleep: { slept.append($0) }) { () async throws -> Int in
                attempts += 1
                throw self.http(400)
            }
            XCTFail("a 400 went through")
        } catch {}
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(slept, [])
    }

    /// A server that stays unwell: three attempts, then its failure.
    func testA5xxStopsWhenTheWaitsRunOut() async {
        var attempts = 0
        do {
            _ = try await IdempotentRetry.run(sleep: { _ in }) { () async throws -> Int in
                attempts += 1
                throw self.http(503)
            }
            XCTFail("a 503 went through")
        } catch {
            guard case APIClient.APIError.http(503, _, _, _, _) = error else {
                return XCTFail("the last failure was not the one thrown: \(error)")
            }
        }
        XCTAssertEqual(attempts, 3)
    }

    /// A 429 is waited out only when it asks for no longer than the plan:
    /// two seconds, yes, and that long; a minute, or no `Retry-After`, no.
    func testA429IsWaitedOutOnlyWhenItIsShort() {
        XCTAssertEqual(IdempotentRetry.delay(after: http(429, retryAfter: 2), planned: .seconds(3)), .seconds(2))
        XCTAssertNil(IdempotentRetry.delay(after: http(429, retryAfter: 60), planned: .seconds(3)))
        XCTAssertNil(IdempotentRetry.delay(after: http(429), planned: .seconds(3)))
    }

    /// The outbox's rule, unchanged: a timeout and a 408 are worth another
    /// try; an unreadable answer is not — the write very likely landed.
    func testTheRuleIsTheOutboxs() {
        XCTAssertEqual(IdempotentRetry.delay(after: URLError(.timedOut), planned: .seconds(1)), .seconds(1))
        XCTAssertEqual(IdempotentRetry.delay(after: http(408), planned: .seconds(1)), .seconds(1))
        XCTAssertNil(IdempotentRetry.delay(after: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "")),
                                           planned: .seconds(1)))
        XCTAssertNil(IdempotentRetry.delay(after: Fails(), planned: .seconds(1)))
    }
}
