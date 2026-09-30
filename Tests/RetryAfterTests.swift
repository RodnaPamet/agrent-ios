import XCTest
@testable import Agrent

/// `Retry-After`, from the header to the sentence — agrent-ios#112.
///
/// Two things were wrong before this, and both were measured rather than
/// supposed. The wait the server sent on a 429 was thrown away, so the outbox
/// retried on its own schedule into a window the server had said was closed.
/// And the 429s of the middleware and the read limiter reached the farmer in
/// ENGLISH, as did a thrown `RateLimitedError`'s "Too many requests": the
/// repo's own `httpText`, run against the middleware's body, returned "Too
/// many requests. Retry after 12 seconds." — `RATE_LIMITED` was in neither
/// table and the message was a real sentence. The auth limiter's 429 was
/// already Bulgarian: its bare-string body carries no message, so the status
/// sentence was reached.
final class RetryAfterParserTests: XCTestCase {

    /// Any fixed instant. The delay-seconds form never reads it.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ header: String?) -> Int? {
        APIClient.retryAfterSeconds(header: header, responseDate: nil, now: now)
    }

    private func response(status: Int, headers: [String: String]) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/api/t/x/locations/1/operations"))
        return try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    /// 2026-09-29 10:00:00 GMT, the moment the server's `Date` header names
    /// in the date-form tests below.
    private func serverNoon() throws -> Date {
        try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "GMT"),
            year: 2026, month: 9, day: 29, hour: 10
        ).date)
    }

    func testDelaySecondsAreRead() {
        XCTAssertEqual(parse("12"), 12)
        XCTAssertEqual(parse("  12 "), 12, "optional whitespace around a field value")
        XCTAssertEqual(parse("1"), 1)
        XCTAssertEqual(parse("3600"), 3600)
        // The auth limiter does not clamp, so "0" is a real answer, and it is
        // carried as 0. Flooring it is policy — `RateLimitGate` — not parsing.
        XCTAssertEqual(parse("0"), 0)
    }

    /// Stricter than the web's `parseInt`, which reads "12abc" as 12.
    /// Anything that is not delay-seconds or an IMF-fixdate is nil, and the
    /// caller waits its own default.
    func testJunkIsIgnored() {
        for junk in [nil, "", "   ", "-1", "1.5", "12abc", "+12", "12 s", "soon", "１２"] {
            XCTAssertNil(parse(junk), "\(junk.debugDescription) was read as a wait")
        }
        // The obsolete date forms RFC 9110 still lets a sender use. This
        // server sends neither, so they are not worth a parser.
        XCTAssertNil(parse("Sunday, 06-Nov-94 08:49:37 GMT"))
        XCTAssertNil(parse("Sun Nov  6 08:49:37 1994"))
    }

    /// A server asking for more than an hour is misconfigured, and honouring
    /// it would park field records for a day. And a value past `Int.max` must
    /// not trap on the way to being capped.
    func testHugeValuesAreCappedWithoutOverflow() {
        XCTAssertEqual(APIClient.retryAfterCeiling, 3600)
        XCTAssertEqual(parse("3601"), 3600)
        XCTAssertEqual(parse("86400"), 3600)
        XCTAssertEqual(parse("1234567890"), 3600)
        XCTAssertEqual(parse("99999999999999999999"), 3600)
    }

    /// THE CLOCK THAT COUNTS IS THE SERVER'S.
    ///
    /// The phone here is ten minutes FAST. The server's `Date` says 10:00:00
    /// and `Retry-After` names 10:01:30 — a ninety-second wait, whatever the
    /// phone believes the time is.
    func testHTTPDateIsMeasuredAgainstTheServersClock() throws {
        let serverSays = "Tue, 29 Sep 2026 10:00:00 GMT"
        let retryAt = "Tue, 29 Sep 2026 10:01:30 GMT"
        let phoneClock = try serverNoon().addingTimeInterval(600)

        XCTAssertEqual(APIClient.retryAfterSeconds(
            header: retryAt, responseDate: serverSays, now: phoneClock), 90)

        // Positive control: against the phone's own clock the same header
        // reads as no wait at all. If these two agreed, the test above would
        // not be telling the clocks apart.
        XCTAssertEqual(APIClient.retryAfterSeconds(
            header: retryAt, responseDate: nil, now: phoneClock), 0)

        // A moment already past is "now", never a negative wait.
        XCTAssertEqual(APIClient.retryAfterSeconds(
            header: "Tue, 29 Sep 2026 09:59:00 GMT", responseDate: serverSays,
            now: phoneClock), 0)

        // And the ceiling holds for a date as it does for seconds.
        XCTAssertEqual(APIClient.retryAfterSeconds(
            header: "Wed, 30 Sep 2026 10:00:00 GMT", responseDate: serverSays,
            now: phoneClock), 3600)
    }

    /// No `Date` on the response: the device clock is the fallback.
    func testWithoutADateHeaderTheDeviceClockIsUsed() throws {
        XCTAssertEqual(APIClient.retryAfterSeconds(
            header: "Tue, 29 Sep 2026 10:01:30 GMT", responseDate: nil,
            now: try serverNoon()), 90)
        // An unreadable `Date` is treated as none.
        XCTAssertEqual(APIClient.retryAfterSeconds(
            header: "Tue, 29 Sep 2026 10:01:30 GMT", responseDate: "yesterday",
            now: try serverNoon()), 90)
    }

    /// The statuses the header means something on — the same pair the web
    /// reads.
    func testOnlyReadOn429And503() throws {
        let cases: [(status: Int, expected: Int?)] = [
            (429, 12), (503, 12), (400, nil), (500, nil), (502, nil), (200, nil),
        ]
        for (status, expected) in cases {
            let r = try response(status: status, headers: ["Retry-After": "12"])
            XCTAssertEqual(APIClient.retryAfterSeconds(for: r), expected, "status \(status)")
        }
    }

    /// HTTP/2 sends header names in lowercase.
    func testHeaderNameIsCaseInsensitive() throws {
        let r = try response(status: 429, headers: ["retry-after": "17"])
        XCTAssertEqual(APIClient.retryAfterSeconds(for: r), 17)
    }

    /// The response's own `Date` header is the one read, through the same
    /// case-insensitive lookup.
    func testTheResponsesOwnDateIsRead() throws {
        let r = try response(status: 429, headers: [
            "retry-after": "Tue, 29 Sep 2026 10:01:30 GMT",
            "date": "Tue, 29 Sep 2026 10:00:00 GMT",
        ])
        let phoneClock = try serverNoon().addingTimeInterval(600)
        XCTAssertEqual(APIClient.retryAfterSeconds(for: r, now: phoneClock), 90)
    }

    func testAMissingHeaderIsNil() throws {
        XCTAssertNil(APIClient.retryAfterSeconds(for: try response(status: 429, headers: [:])))
    }
}

/// The wait survives the trip from the response to wherever it is used.
final class RetryAfterCarryingTests: XCTestCase {

    func testTheWaitRidesOnTheError() {
        let e = APIClient.APIError.http(
            status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: 12)
        XCTAssertEqual(e.retryAfterSeconds, 12)

        // Every construction written before the field existed still
        // compiles, and carries nothing.
        XCTAssertNil(APIClient.APIError.http(status: 429, code: nil, message: nil)
            .retryAfterSeconds)
        XCTAssertNil(APIClient.APIError.notSignedIn.retryAfterSeconds)
        XCTAssertNil(APIClient.APIError.conflict(currentVersion: 2, expectedVersion: 1)
            .retryAfterSeconds)
    }

    /// THE SILENT DROP. `humanised` rebuilds the error, and the rebuild
    /// compiles without the new label because it has a default — so leaving
    /// it out loses the server's wait without a word from the compiler.
    ///
    /// The input takes the REBUILD path on purpose: a bare sentence in `code`
    /// and no message. An error that went through untouched would keep its
    /// wait whatever `humanised` did, and prove nothing.
    func testHumanisedKeepsRetryAfter() {
        let raw = APIClient.APIError.http(
            status: 429, code: "Too many uploads, try later", message: nil,
            retryAfterSeconds: 30)
        guard case APIClient.APIError.http(let status, let code, let message, _, let seconds) =
                SpatialImportAPI.humanised(raw) else {
            return XCTFail("shape changed")
        }
        XCTAssertNil(code, "positive control: this went through the rebuild")
        XCTAssertEqual(message, "Too many uploads, try later")
        XCTAssertEqual(status, 429)
        XCTAssertEqual(seconds, 30, "the rebuild dropped the server's wait")
    }

    /// The one fact that explains why the outbox went quiet, and a number —
    /// so it is safe to persist under `Log`'s three rules. The message still
    /// is not.
    func testTheLogSummaryCarriesTheWait() {
        let limited = APIClient.APIError.http(
            status: 429, code: "RATE_LIMITED",
            message: "Too many requests. Retry after 12 seconds.", retryAfterSeconds: 12)
        XCTAssertEqual(Log.summary(for: limited), "APIError.http(429, RATE_LIMITED, retry-after 12s)")
        XCTAssertFalse(Log.summary(for: limited).contains("Too many"), "the message reached the log")

        XCTAssertEqual(
            Log.summary(for: APIClient.APIError.http(
                status: 429, code: nil, message: nil, retryAfterSeconds: 0)),
            "APIError.http(429, retry-after 0s)")

        // The summaries that existed before are unchanged, character for
        // character — somebody greps for them.
        XCTAssertEqual(
            Log.summary(for: APIClient.APIError.http(
                status: 404, code: "INVALID_PARCEL", message: "Parcel not found")),
            "APIError.http(404, INVALID_PARCEL)")
        XCTAssertEqual(
            Log.summary(for: APIClient.APIError.http(status: 500, code: nil, message: nil)),
            "APIError.http(500)")
    }

    private var clientSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/API/APIClient.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A source check, because nothing in this suite puts a 429 through
    /// `APIClient`. The unit tests run with no seam at all, and the UI-test
    /// fixture protocol serves recorded GETs with 200 and refuses everything
    /// else with 501 — never a 429, never a `Retry-After`. Both throw sites
    /// must pass the wait; the refresh one matters because the auth limiter's
    /// 429 surfaces from `send` as the failure of the request that needed the
    /// refresh.
    func testBothThrowSitesPassTheWait() {
        let source = clientSource
        XCTAssertTrue(source.contains("actor APIClient"), "read the wrong file")
        XCTAssertTrue(
            source.contains("retryAfterSeconds: Self.retryAfterSeconds(for: http)"),
            "send's default arm no longer passes the response's wait")
        XCTAssertTrue(
            source.contains(".flatMap { Self.retryAfterSeconds(for: $0) }"),
            "the token refresh's failure no longer passes its wait")
    }

    /// A 429 ON THE TOKEN REFRESH IS NOT TOLD TO SIGN OUT.
    ///
    /// The refresh arm names an uncoded failure `TOKEN_REFRESH_FAILED`, and a
    /// code is looked up BEFORE the 429 rule — so a proxy's bodyless 429 there
    /// would have said «Излезте от менюто и влезте отново», and sign-in spends
    /// the same auth limiter. A source check for the throw, which lives inside
    /// the refresh closure; the rest is what each code would have said.
    func testABodylessRefresh429IsNotToldToSignOut() {
        XCTAssertTrue(
            clientSource.contains(#"code ?? (status == 429 ? nil : "TOKEN_REFRESH_FAILED")"#),
            "the refresh arm gives a bodyless 429 the sign-out code again")

        let tooMany = UserMessage.statusText(429)
        XCTAssertEqual(UserMessage.httpText(status: 429, code: nil, message: nil), tooMany)
        // Positive control: the invented code WOULD have won over the rule.
        XCTAssertNotEqual(
            UserMessage.httpText(status: 429, code: "TOKEN_REFRESH_FAILED", message: nil), tooMany,
            "the code no longer outranks the 429 rule, so this test holds nothing")
        // Any other status keeps the code, which is why it was invented: it
        // names the session, where the status alone blamed the data.
        XCTAssertNotEqual(
            UserMessage.httpText(status: 400, code: "TOKEN_REFRESH_FAILED", message: nil),
            UserMessage.statusText(400))
    }
}

/// The 429 bodies the server actually sends, read out of its source. The
/// numeric `retryAfterSeconds` in them is deliberately NOT modelled, and
/// these hold that the envelope still decodes around it.
final class RateLimitEnvelopeTests: XCTestCase {

    private func envelope(_ json: String) -> APIClient.ErrorEnvelope.Err? {
        APIClient.envelope(from: Data(json.utf8))
    }

    /// The middleware limiter's body, which the outbox's route and the
    /// messaging writes meet.
    func testTheMiddlewareBodyStillDecodes() {
        let e = envelope(#"""
        {"error":{"code":"RATE_LIMITED","message":"Too many requests. Retry after 12 seconds.","retryAfterSeconds":12,"scope":"api-mutation"}}
        """#)
        XCTAssertEqual(e?.code, "RATE_LIMITED")
        XCTAssertEqual(e?.message, "Too many requests. Retry after 12 seconds.")
    }

    /// The auth limiter's: a bare string under `error`, a number beside it.
    func testTheAuthLimitersBareBodyDecodes() {
        let e = envelope(#"{"error":"RATE_LIMITED","retryAfterSeconds":0}"#)
        XCTAssertEqual(e?.code, "RATE_LIMITED")
        XCTAssertNil(e?.message)
    }
}

/// What a 429 says, in Bulgarian, on every surface.
final class RateLimitMessageTests: XCTestCase {

    private var tooMany: String { UserMessage.statusText(429) }

    /// FAILED BEFORE THIS CHANGE, with the server's own sentence on screen.
    func testAServerRateLimitReadsInBulgarian() {
        let text = UserMessage.httpText(
            status: 429, code: "RATE_LIMITED",
            message: "Too many requests. Retry after 12 seconds.")
        XCTAssertEqual(text, tooMany)
        XCTAssertFalse(text.contains("Too many"), text)

        // The read limiter's sentence, which is different English.
        XCTAssertEqual(UserMessage.httpText(
            status: 429, code: "RATE_LIMITED",
            message: "Too many read requests. Retry after 3 seconds."), tooMany)

        // And through `text(for:)`, which is what every screen calls — with
        // the wait on the error, which that static line does not read.
        XCTAssertEqual(UserMessage.text(for: APIClient.APIError.http(
            status: 429, code: "RATE_LIMITED",
            message: "Too many requests. Retry after 12 seconds.",
            retryAfterSeconds: 12)), tooMany)
    }

    /// A STATUS rule, so the next limiter with a code nobody has mapped yet
    /// is Bulgarian too — the argument `isHumanSentence` makes for the next
    /// thirty call sites.
    func testAFutureCoded429StillReadsInBulgarian() {
        XCTAssertEqual(UserMessage.httpText(
            status: 429, code: "EXPORT_QUOTA_EXCEEDED",
            message: "You have exported too often today."), tooMany)
        XCTAssertEqual(UserMessage.httpText(
            status: 429, code: nil, message: "Slow down, please."), tooMany)
    }

    /// And it is a 429's rule alone. Any other status with an unmapped code
    /// still shows the server's sentence, which is the ordinary path.
    func testOtherStatusesStillFallBackToTheServersSentence() {
        XCTAssertEqual(UserMessage.httpText(
            status: 400, code: "SOME_FUTURE_CODE", message: "Delta must be non-zero."),
            "Delta must be non-zero.")
    }

    /// Up to two minutes the wait-aware line IS the status sentence,
    /// verbatim — one sentence for one situation, wherever it is shown.
    func testTheShortWaitReusesTheExistingSentenceVerbatim() {
        for remaining: Duration in [.milliseconds(300), .seconds(40), .seconds(120)] {
            XCTAssertEqual(UserMessage.rateLimited(remaining: remaining), tooMany,
                           "\(remaining)")
        }
    }

    /// ROUNDED UP, so the promise is never earlier than the gate.
    ///
    /// Built in `Calendar.current` and compared through `BgDate.time`, so the
    /// assertion is the invariant and not this runner's zone: whatever zone
    /// it is, the minute constructed is the minute shown.
    func testALongWaitNamesTheClockTimeRoundedUp() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 29, hour: 14, minute: 30, second: 10)))
        let at1433 = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 29, hour: 14, minute: 33)))

        // 121 seconds after 14:30:10 is 14:32:11 — shown as 14:33, not 14:32.
        let text = UserMessage.rateLimited(remaining: .seconds(121), now: now)
        XCTAssertEqual(text, "Твърде много заявки. Опитайте отново в \(BgDate.time(at1433)).")
        XCTAssertTrue(text.contains("14:33"), text)

        // A moment exactly on the minute is not pushed to the next one:
        // 14:30:10 plus 170 seconds is 14:33:00.
        XCTAssertEqual(
            UserMessage.rateLimited(remaining: .seconds(170), now: now),
            "Твърде много заявки. Опитайте отново в \(BgDate.time(at1433)).")
    }

    /// The queue resumes by itself. A caption that told the farmer to try
    /// again would send them to a button the banner has hidden.
    func testTheOutboxCaptionNeverAsksTheFarmerToAct() {
        for remaining: Duration in [.seconds(1), .seconds(40), .seconds(120),
                                    .seconds(121), .seconds(3600)] {
            let text = UserMessage.outboxRateLimited(remaining: remaining)
            XCTAssertFalse(text.lowercased().contains("опитайте"), text)
            XCTAssertTrue(text.contains("автоматично"), text)
            XCTAssertTrue(text.hasPrefix("Твърде много заявки."), text)
            XCTAssertTrue(text.hasSuffix("."), text)
        }
        XCTAssertEqual(
            UserMessage.outboxRateLimited(remaining: .seconds(40)),
            "Твърде много заявки. Изпращането продължава автоматично след малко.")
    }
}
