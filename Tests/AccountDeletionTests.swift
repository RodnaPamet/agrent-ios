import XCTest
@testable import Agrent

/// Deleting one's own account in the app (agrent-ios#281). Nothing here
/// sends the request, and nothing here ends a session: `AuthClient`'s
/// hand-off clears the Keychain, which on the owner's simulator is a real
/// sign-in. The shapes, the words and the one call site are what is tested.
@MainActor
final class AccountDeletionTests: XCTestCase {

    // MARK: - The answers

    func testTheRequestAnswerKeepsTheServersDate() throws {
        let json = #"{"requested":true,"alreadyRequested":false,"erasesAt":"2026-11-10T21:04:00.000Z","graceDays":30,"sessionsRevoked":2}"#
        let answer = try JSONDecoder().decode(AccountDeletionAPI.Requested.self, from: Data(json.utf8))
        XCTAssertFalse(answer.alreadyRequested)
        XCTAssertEqual(answer.erasesAt, BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        XCTAssertNotNil(answer.erasesAt, "precondition: the fractional instant parses")

        // Asked twice: the ORIGINAL date stands, and it is the one kept.
        let again = #"{"requested":true,"alreadyRequested":true,"erasesAt":"2026-11-01T08:00:00Z","graceDays":30,"sessionsRevoked":0}"#
        let second = try JSONDecoder().decode(AccountDeletionAPI.Requested.self, from: Data(again.utf8))
        XCTAssertTrue(second.alreadyRequested)
        XCTAssertEqual(second.erasesAt, BgDate.parseInstant("2026-11-01T08:00:00Z"))

        // The spec makes `erasesAt` nullable; a missing date costs the date,
        // never the answer that the request was recorded.
        let undated = #"{"requested":true,"alreadyRequested":false,"erasesAt":null,"graceDays":30,"sessionsRevoked":1}"#
        XCTAssertNil(try JSONDecoder().decode(AccountDeletionAPI.Requested.self, from: Data(undated.utf8)).erasesAt)
    }

    /// Nothing pending is success, not an error.
    func testACancelWithNothingPendingIsStillAnAnswer() throws {
        let json = #"{"requested":false,"wasRequested":false}"#
        XCTAssertEqual(try JSONDecoder().decode(AccountDeletionAPI.Cancelled.self, from: Data(json.utf8)),
                       .init(wasRequested: false))
    }

    // MARK: - The words

    /// The date is the server's, said in full; without one, the sentence
    /// still says how to undo it.
    func testTheSignInScreenSaysTheDateAndTheWayBack() throws {
        let date = try XCTUnwrap(BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        let dated = AccountDeletionText.requested(erasesAt: date)
        XCTAssertTrue(dated.contains(BgDate.fullEndingSentence(date)), dated)
        XCTAssertTrue(dated.contains("възстановите"), "the way back is not said")
        XCTAssertFalse(dated.contains(".."), "the year's «г.» and a full stop: \(dated)")
        let undated = AccountDeletionText.requested(erasesAt: nil)
        XCTAssertTrue(undated.contains("възстановите"))
        for text in [dated, undated, AccountDeletionText.confirmMessage, AccountDeletionText.sessionEnded]
            + AccountDeletionText.explanation {
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    /// The grace period is the server's (`DELETION_GRACE_DAYS`), so no
    /// number of days is written into the page before the request.
    func testThePageWritesNoNumberOfDays() {
        for paragraph in AccountDeletionText.explanation + [AccountDeletionText.confirmMessage] {
            XCTAssertFalse(paragraph.contains { $0.isNumber }, paragraph)
        }
    }

    /// Past the grace period there is nothing to cancel, and the app says so.
    func testAnErasedAccountIsSaidInBulgarian() {
        let text = UserMessage.httpText(status: 404, code: "ACCOUNT_ALREADY_ERASED",
                                        message: "This account has already been erased.")
        XCTAssertEqual(text, "Профилът вече е изтрит и не може да бъде възстановен.")

        // A suspended (or terminated) account is told so, not that it lacks a
        // right: the server's message is the bare code, which is no sentence.
        XCTAssertEqual(UserMessage.httpText(status: 403, code: "ACCOUNT_SUSPENDED", message: "ACCOUNT_SUSPENDED"),
                       "Профилът Ви е спрян и не може да се използва.")
    }

    // MARK: - The recovery screen's signal

    /// `user.deletion` on `/me`: read when set, and absent, null or
    /// unreadable all mean nothing pending — never the identity lost with it.
    func testMeSaysWhenADeletionIsPending() throws {
        func me(_ deletion: String) throws -> CurrentUser {
            let json = #"{"user":{"id":"u1","name":null,"email":null,"role":"OWNER""# + deletion + "}}"
            return try JSONDecoder().decode(CurrentUser.self, from: Data(json.utf8))
        }
        let pending = try me(#","deletion":{"requestedAt":"2026-10-11T21:04:00.000Z","erasesAt":"2026-11-10T21:04:00.000Z"}"#)
        XCTAssertEqual(pending.deletion?.erasesAt, BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        XCTAssertNotNil(pending.deletion?.requestedAt)

        XCTAssertNil(try me("").deletion, "an older server stranded someone on the recovery screen")
        XCTAssertNil(try me(#","deletion":null"#).deletion)
        let unreadable = try me(#","deletion":"soon""#)
        XCTAssertNil(unreadable.deletion)
        XCTAssertEqual(unreadable.id, "u1", "an unreadable field cost the identity")

        // Kept through the open farm's role, as everything of the person's is.
        XCTAssertEqual(pending.inFarm(role: "READER").deletion, pending.deletion)
    }

    /// The server's date, and what restoring does not bring back.
    func testTheRecoveryScreenSaysTheDateAndWhatRestoringDoes() throws {
        let date = try XCTUnwrap(BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        let dated = AccountDeletionText.pending(erasesAt: date)
        XCTAssertTrue(dated.contains(BgDate.fullEndingSentence(date)), dated)
        let undated = AccountDeletionText.pending(erasesAt: nil)
        for text in [dated, undated] {
            XCTAssertTrue(text.contains("влезете отново"), "the other devices' sign-out is not said: \(text)")
            XCTAssertTrue(text.hasSuffix("."), text)
            // The year's «г.» is the full stop; a second one read «2026 г..».
            XCTAssertFalse(text.contains(".."), text)
        }
    }

    /// Only a signed-in session is moved to the recovery screen by `/me`;
    /// a code being asked for is left alone, and nothing restores outside it.
    func testOnlyASignedInSessionIsMovedToTheRecoveryScreen() async {
        let auth = AuthClient()
        auth.awaitCode(.init(ticket: "t", verifier: "v", deadline: Date().addingTimeInterval(300)))
        auth.deletionPendingSeen(.init(requestedAt: nil, erasesAt: nil))
        XCTAssertEqual(auth.state, .codeRequired)
        await auth.restoreAccount()
        XCTAssertEqual(auth.state, .codeRequired, "a restore ran outside the recovery screen")
        XCTAssertFalse(auth.restoringAccount)
    }

    // MARK: - Fired from one place

    /// The request is an outward-facing write that revokes every session, so
    /// it is sent from exactly one place: `AuthClient.requestAccountDeletion`,
    /// which only the confirmation on `DeleteAccountView` calls. Read from the
    /// source because nothing at runtime may send it; the positive control
    /// is that each one call is there.
    func testTheRequestIsSentOnlyFromTheConfirmation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = try FileManager.default
            .subpathsOfDirectory(atPath: root.appendingPathComponent("Agrent").path)
            .filter { $0.hasSuffix(".swift") }
        var senders: [String] = []
        var askers: [String] = []
        var cancellers: [String] = []
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent("Agrent").appendingPathComponent(path),
                                  encoding: .utf8)
            let code = SignOutHygieneTests.code(text)
            if code.contains("AccountDeletionAPI.request()") { senders.append(path) }
            if code.contains("auth.requestAccountDeletion()") { askers.append(path) }
            if code.contains("AccountDeletionAPI.cancel()") { cancellers.append(path) }
        }
        XCTAssertEqual(senders, ["Auth/AuthClient.swift"])
        XCTAssertEqual(askers, ["Account/DeleteAccountView.swift"])
        // And the cancel, from the recovery screen's one action.
        XCTAssertEqual(cancellers, ["Auth/AuthClient.swift"])
    }
}
