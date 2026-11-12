import XCTest
@testable import Agrent

/// A refresh the server refuses ends the session on the phone too
/// (2026-11-12). The owner's 14-day session had expired; the refused refresh
/// cleared the tokens but left him inside the app, over its cache, with every
/// flag off and every request failing before it left the phone. The
/// «Ортофотокарта» went missing and nothing said why.
///
/// Nothing here ends a session for real: the decision is pure, and the live
/// notification is sent only to states that must not move.
@MainActor
final class SessionRefusedTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// A session in the app ends; every other screen already says what it
    /// should.
    func testOnlyASessionInTheAppEnds() {
        typealias S = AuthClient.State
        XCTAssertTrue(AuthClient.endsOnRefusal(.signedIn))
        XCTAssertTrue(AuthClient.endsOnRefusal(.termsPending))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stay: [S] = [.signedOut, .signingIn, .codeRequired, .suspended(erasesAt: date),
                         .deletionPending(erasesAt: date), .failed("x")]
        for state in stay {
            XCTAssertFalse(AuthClient.endsOnRefusal(state), "\(state) was ended")
        }
    }

    /// The notification reaches `AuthClient`, and a state that must stay,
    /// stays.
    func testTheRefusalReachesAuthAndLeavesACodeScreenAlone() {
        let auth = AuthClient()
        auth.awaitCode(.init(ticket: "t", verifier: "v", deadline: Date().addingTimeInterval(300)))
        NotificationCenter.default.post(name: APIClient.sessionRefusedNotification, object: nil)
        XCTAssertEqual(auth.state, .codeRequired, "a code screen was ended by a refused refresh")
    }

    /// The refused branch posts only after clearing THIS session's pair, and
    /// `AuthClient` listens. Read from the source: the branch runs only
    /// against a live server.
    func testTheRefusedBranchPostsAfterItsOwnClear() throws {
        let client = try source("Agrent/API/APIClient.swift")
        let clear = try XCTUnwrap(client.range(of: "if TokenStore.clear(ifRefreshToken: seen.refreshToken) {"))
        let post = try XCTUnwrap(client.range(of: "post(name: Self.sessionRefusedNotification"))
        XCTAssertLessThan(clear.lowerBound, post.lowerBound, "posted before the clear decided")
        XCTAssertLessThan(client.distance(from: clear.upperBound, to: post.lowerBound), 120,
                          "the post is not inside the clear's branch")
        let auth = try source("Agrent/Auth/AuthClient.swift")
        XCTAssertTrue(auth.contains("forName: APIClient.sessionRefusedNotification"), "nobody listens")
        // Positive control: the suspension's own wiring reads the same way.
        XCTAssertTrue(auth.contains("forName: APIClient.suspendedNotification"))
    }

    /// The sign-in screen says why, in Bulgarian, with a full stop.
    func testTheNoticeSaysWhy() {
        let text = SignInText.sessionRefused
        XCTAssertTrue(text.hasSuffix("."))
        XCTAssertTrue(text.contains("Влезте отново"))
        XCTAssertNil(text.range(of: "[ыэё]", options: .regularExpression), "a Russianism")
    }
}
