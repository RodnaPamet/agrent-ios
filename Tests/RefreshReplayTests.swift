import XCTest
@testable import Agrent

/// The owner was signed out twice in one afternoon, 34 minutes into a
/// session. The production rows recorded both as
/// `security:refresh-replayed`: refresh tokens rotate and are single-use, and
/// presenting a consumed one burns the whole rotation lineage AND the
/// session, immediately and irreversibly.
///
/// The app was the thief. Two requests go out with the same expired access
/// token, both come back 401, the first refreshes and rotates, and the second
/// then refreshes with the token IT captured — consumed 1.02 seconds earlier.
///
/// The old single-flight guard could not see this. It covered concurrency
/// only while a refresh was IN FLIGHT, and the second caller never overlapped
/// the first: it arrived just after.
final class RefreshReplayTests: XCTestCase {

    private func tokens(_ refresh: String, expiresIn: TimeInterval = 900) -> Tokens {
        Tokens(
            accessToken: "access-for-\(refresh)",
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// THE regression. A caller holding a token that has since been rotated
    /// away must NOT send it — that request is what the server scores as
    /// theft, and the cost is the entire session.
    func testACallerHoldingARotatedTokenDoesNotSendIt() {
        let stale = tokens("rt-1")
        let current = tokens("rt-2")
        XCTAssertEqual(
            APIClient.refreshDecision(seen: stale, stored: current),
            .alreadyRotated(current),
            "would have replayed rt-1 and burned the session"
        )
    }

    /// And it gets the winner's result rather than an error: the rotation it
    /// needed already happened, so there is nothing to fail about.
    func testTheLateCallerGetsTheRotatedTokens() {
        guard case .alreadyRotated(let got) = APIClient.refreshDecision(
            seen: tokens("rt-1"), stored: tokens("rt-2")
        ) else { return XCTFail("expected alreadyRotated") }
        XCTAssertEqual(got.refreshToken, "rt-2")
        XCTAssertEqual(got.accessToken, "access-for-rt-2")
    }

    /// The ordinary path still has to work, or the fix is a sign-out of its
    /// own: nobody has rotated, so this caller must actually refresh.
    func testTheFirstCallerStillPerformsTheRefresh() {
        let t = tokens("rt-1")
        XCTAssertEqual(APIClient.refreshDecision(seen: t, stored: t), .perform)
    }

    /// Identity is the REFRESH token, not the access token or the expiry.
    /// Two callers can hold different access tokens from the same rotation,
    /// and comparing whole values would send them both down the perform
    /// path — reintroducing the replay through a stricter-looking check.
    func testOnlyTheRefreshTokenDecidesIdentity() {
        let seen = Tokens(
            accessToken: "older-access", refreshToken: "rt-1",
            expiresAt: Date().addingTimeInterval(60)
        )
        let stored = Tokens(
            accessToken: "newer-access", refreshToken: "rt-1",
            expiresAt: Date().addingTimeInterval(900)
        )
        XCTAssertEqual(APIClient.refreshDecision(seen: seen, stored: stored), .perform)
    }

    /// An empty keychain is a signed-out app, not a rotation to adopt.
    /// Returning `.perform` here would send a refresh with a token nothing
    /// has, and earn a 401 for a state the app could have known locally.
    func testNoStoredTokensMeansSignedOut() {
        XCTAssertEqual(APIClient.refreshDecision(seen: tokens("rt-1"), stored: nil), .signedOut)
    }

    /// The sequence that actually happened, as one test.
    ///
    /// Two requests captured the same token; A rotated; B arrived 1.02s
    /// later. Under the old rule B sent `rt-1` and the session died. Under
    /// this one B sends nothing and continues on `rt-2`.
    func testTheProductionSequence() {
        let captured = tokens("rt-1")

        // A refreshes first and the keychain moves on.
        XCTAssertEqual(APIClient.refreshDecision(seen: captured, stored: captured), .perform)
        let afterA = tokens("rt-2")

        // B, 1.02s later, still holding what it captured before A ran.
        let decision = APIClient.refreshDecision(seen: captured, stored: afterA)
        XCTAssertEqual(decision, .alreadyRotated(afterA))
        if case .perform = decision {
            XCTFail("rt-1 would go on the wire — this is the replay")
        }
    }
}

/// The THIRD shape of the sign-out, and the only one that was the
/// client's alone.
///
/// Measured: at 18:18 a refresh returned **502** — the server restarting
/// for a deploy — and the app cleared the tokens, because a gateway error
/// and a rejected credential took the same branch. The refresh token was
/// perfectly valid and was destroyed anyway.
///
/// It is invisible from the server side: no session is revoked, so the
/// query that finds replayed-token burns correctly reports zero while the
/// operator is looking at a sign-in screen. Two true statements and one
/// signed-out farmer.
final class RefreshInvalidationTests: XCTestCase {

    /// The server returns 401 `invalid_grant` for EVERY genuine refusal —
    /// unparseable, missing, unknown, revoked, expired, replayed. So 401
    /// is the whole set of "this token is dead".
    func testOnlyA401InvalidatesTheToken() {
        XCTAssertTrue(APIClient.invalidatesToken(status: 401))
    }

    /// THE regression. A deploy must not sign anybody out.
    func testAGatewayErrorDoesNotInvalidateTheToken() {
        for status in [500, 502, 503, 504] {
            XCTAssertFalse(
                APIClient.invalidatesToken(status: status),
                "\(status) would clear a valid refresh token"
            )
        }
    }

    /// Nor does anything else the server might say. A question that was
    /// not answered is not a no.
    func testNothingElseInvalidatesEither() {
        for status in [400, 403, 404, 408, 418, 429, -1] {
            XCTAssertFalse(
                APIClient.invalidatesToken(status: status),
                "\(status) would clear a valid refresh token"
            )
        }
    }
}
