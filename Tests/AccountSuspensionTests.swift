import XCTest
@testable import Agrent

/// The suspended account as one screen (agrent-ios#283): marked on the pair
/// by `APIClient` from any route's `403 ACCOUNT_SUSPENDED`, lifted by `/me`'s
/// next 200, and shown by `SuspendedView` with Изход and, for the person's
/// own deletion, the one way to stop it.
///
/// Nothing here sends the cancel or ends a session: `cancelDeletion` is
/// driven only where its guard returns, and the wiring that has no runtime seam is
/// read from source, each with a positive control.
@MainActor
final class AccountSuspensionTests: XCTestCase {

    private let pair = Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0))

    // MARK: - The marks, on the pair

    /// A pair stored before the fields existed is not suspended; a marked one
    /// round-trips with its date.
    func testTheSuspensionIsKeptWithTheTokens() throws {
        let old = #"{"accessToken":"a","refreshToken":"r","expiresAt":0}"#
        let decoded = try JSONDecoder().decode(Tokens.self, from: Data(old.utf8))
        XCTAssertNil(decoded.suspended, "an older pair read as suspended")
        XCTAssertNil(decoded.suspendedErasesAt)

        let date = try XCTUnwrap(BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        var marked = pair
        marked.suspended = true
        marked.suspendedErasesAt = date
        let again = try JSONDecoder().decode(Tokens.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(again.suspended, true)
        XCTAssertEqual(again.suspendedErasesAt, date)
    }

    /// Only `/me`'s refusal says whether the person's own deletion is
    /// pending; another route's — or a `/me` that a cancel overtook — is the
    /// same suspension saying nothing about it, and must not change the date.
    func testOnlyMesRefusalSaysWhetherADeletionCanBeCancelled() throws {
        let date = try XCTUnwrap(BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        let fromMe = APIClient.suspending(pair, saysDeletion: true, erasesAt: date)
        XCTAssertEqual(fromMe.suspended, true)
        XCTAssertEqual(fromMe.suspendedErasesAt, date)

        let fromAFarmRoute = APIClient.suspending(fromMe, saysDeletion: false, erasesAt: nil)
        XCTAssertEqual(fromAFarmRoute.suspended, true)
        XCTAssertEqual(fromAFarmRoute.suspendedErasesAt, date, "a farm route's refusal wiped /me's date")

        // A `/me` sent before a cancel and answered after it: its date is the
        // one the cancel removed, and must not come back.
        var cancelled = fromMe
        cancelled.suspendedErasesAt = nil
        XCTAssertNil(APIClient.suspending(cancelled, saysDeletion: false, erasesAt: date).suspendedErasesAt,
                     "a late /me brought a cancelled deletion back")

        // `/me` refusing without a date is its word that nothing can be
        // cancelled: a moderator's termination, or the cancel already done.
        XCTAssertNil(APIClient.suspending(fromMe, saysDeletion: true, erasesAt: nil).suspendedErasesAt)

        let lifted = APIClient.lifting(fromMe)
        XCTAssertNil(lifted.suspended)
        XCTAssertNil(lifted.suspendedErasesAt)
        XCTAssertEqual(lifted.refreshToken, pair.refreshToken, "lifting cost the session")
    }

    // MARK: - The wiring, which has no runtime seam

    /// Code only: a commented-out line must not pass for the wiring.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return SignOutHygieneTests.code(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    private func assertMatches(_ text: String, _ pattern: String, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), message, file: file, line: line)
    }

    /// From ANY route, as the terms gate is; lifted by `/me`'s 200 and the
    /// date taken by the cancel's, both inside the success branch; carried
    /// across a refresh; turned into the screen by `AuthClient`.
    func testASuspensionFromAnyRouteOpensTheSuspendedScreen() throws {
        let api = try source("Agrent/API/APIClient.swift")
        // Positive control: the branch it sits beside is still there.
        assertMatches(api, #"if http\.statusCode == 403, env\?\.code == "TERMS_ACCEPTANCE_REQUIRED" \{\s*markTermsPending\(for: tokens\)"#,
                      "positive control: the terms gate's branch moved")
        assertMatches(api, #"if http\.statusCode == 403, env\?\.code == "ACCOUNT_SUSPENDED" \{\s*markSuspended\(for: tokens,\s*saysDeletion: path == MeAPI\.path && cancelsBefore == deletionCancels,"#,
                      "a suspension is only one screen's error")
        assertMatches(api, #"case 200\.\.<300:\s*if path == MeAPI\.path \{ liftSuspension\(for: tokens\) \}\s*if method == "DELETE", path == AccountDeletionAPI\.path \{ deletionCancelled\(for: tokens\) \}\s*return \(data, http\)"#,
                      "a lifted suspension or a cancelled deletion stays on the pair")
        assertMatches(api, #"fresh\.suspended = stored\?\.suspended\s*fresh\.suspendedErasesAt = stored\?\.suspendedErasesAt\s*TokenStore\.save\(fresh\)"#,
                      "a token refresh drops the suspension")

        let auth = try source("Agrent/Auth/AuthClient.swift")
        assertMatches(auth, #"forName: APIClient\.termsPendingNotification, object: nil, queue: \.main"#, "positive control")
        assertMatches(auth, #"forName: APIClient\.suspendedNotification, object: nil, queue: \.main\s*\) \{ \[weak self\] _ in\s*MainActor\.assumeIsolated \{ self\?\.suspensionSeen\(\) \}"#,
                      "nothing turns the refusal into the suspended screen")

        let app = try source("Agrent/AgrentApp.swift")
        assertMatches(app, #"case \.deletionPending\(let erasesAt\):\s*DeletionPendingView\(erasesAt: erasesAt\)"#, "positive control")
        assertMatches(app, #"case \.suspended\(let erasesAt\):\s*SuspendedView\(erasesAt: erasesAt\)"#,
                      "the suspended state opens no screen of its own")
    }

    // MARK: - Where a refusal takes the session

    /// A signed-in session and the terms screen move to the suspended
    /// screen; the screen itself takes `/me`'s newer date; a sign-in, a code
    /// and the recovery screen decide for themselves; an unmarked pair moves
    /// nothing.
    func testWhereASuspensionRefusalTakesTheSession() throws {
        let date = try XCTUnwrap(BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        var marked = pair
        marked.suspended = true
        marked.suspendedErasesAt = date
        typealias S = AuthClient.State

        XCTAssertEqual(AuthClient.stateOnSuspension(.signedIn, tokens: marked), .suspended(erasesAt: date))
        XCTAssertEqual(AuthClient.stateOnSuspension(.termsPending, tokens: marked), .suspended(erasesAt: date),
                       "a refusal from the terms routes left the terms screen up")
        XCTAssertEqual(AuthClient.stateOnSuspension(.suspended(erasesAt: nil), tokens: marked),
                       .suspended(erasesAt: date), "the screen missed /me's date")
        XCTAssertNil(AuthClient.stateOnSuspension(.suspended(erasesAt: date), tokens: marked),
                     "an unchanged screen was rebuilt")
        let decideForThemselves: [S] = [.signingIn, .codeRequired, .deletionPending(erasesAt: date),
                                        .signedOut, .failed("x")]
        for state in decideForThemselves {
            XCTAssertNil(AuthClient.stateOnSuspension(state, tokens: marked), "\(state) was moved")
        }
        // Positive control for the guard: the same states, unmarked.
        XCTAssertNil(AuthClient.stateOnSuspension(.signedIn, tokens: pair), "an unmarked pair moved the session")
        XCTAssertNil(AuthClient.stateOnSuspension(.signedIn, tokens: nil), "no pair moved the session")
    }

    // MARK: - Nothing outside the screen

    /// The cancel and the recheck act on the suspended screen only: a code
    /// being asked for is left alone, and nothing is sent from anywhere else.
    func testOnlyTheSuspendedScreenCancelsADeletion() async {
        let auth = AuthClient()
        auth.awaitCode(.init(ticket: "t", verifier: "v", deadline: Date().addingTimeInterval(300)))
        await auth.cancelDeletion()
        XCTAssertEqual(auth.state, .codeRequired, "a cancel ran outside the suspended screen")
        XCTAssertFalse(auth.cancellingDeletion)
        await auth.recheckSuspension()
        XCTAssertEqual(auth.state, .codeRequired, "a recheck ran outside the suspended screen")
    }

    // MARK: - The words

    /// The web's `/suspended`, word for word (agri-saas #1665): the two
    /// clients never say different things about the same account.
    func testTheScreenSaysWhatTheWebSays() {
        XCTAssertEqual(AccountSuspensionText.title, "Достъпът до профила Ви е спрян")
        XCTAssertEqual(AccountSuspensionText.body,
                       "Докато спирането е в сила, не можете да отваряте стопанството си. "
                       + "Всичко вече записано се запазва.")
        // Nothing the server cannot make true (agri-saas #1667): no email
        // that may not have been sent, no appeal that does not exist.
        for text in [AccountSuspensionText.title, AccountSuspensionText.body,
                     AccountSuspensionText.deletionCancelled,
                     AccountSuspensionText.deletionPending(erasesAt: Date(timeIntervalSince1970: 0))] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("имейл"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("обжал"), text)
        }
    }

    /// Before the cancel and after it, the same two facts: the deletion can
    /// end, the access does not come back. And the cancel is «отмени», never
    /// «спри»: «спирам» is the suspension's word on this screen.
    func testCancellingTheDeletionSaysTheAccessStaysSuspended() throws {
        let date = try XCTUnwrap(BgDate.parseInstant("2026-11-10T21:04:00.000Z"))
        let before = AccountSuspensionText.deletionPending(erasesAt: date)
        // The date ends its sentence with the year's «г.» and the next one
        // follows: no second full stop, no missing one.
        XCTAssertTrue(before.contains("\(BgDate.fullEndingSentence(date)) Можете"), before)
        XCTAssertFalse(before.contains(".."), before)
        XCTAssertTrue(before.contains("ще остане спрян"), "the offer hides that the suspension stays: \(before)")

        let after = AccountSuspensionText.deletionCancelled
        XCTAssertTrue(after.contains("Изтриването е отменено"), after)
        XCTAssertTrue(after.contains("остава спрян"), "the cancel reads as access restored: \(after)")
        XCTAssertFalse(after.contains("възстанов"), "the cancel reads as the account restored: \(after)")

        for text in [before, after, AccountSuspensionText.cancel, AccountSuspensionText.cancelling] {
            XCTAssertFalse(text.contains("Спри") || text.contains("спрете") || text.contains("Спиране")
                           || text.contains("изтриването е спряно"),
                           "the cancel borrows the suspension's verb: \(text)")
        }
        XCTAssertEqual(A11y.Spoken.cancelDeletion.first, AccountSuspensionText.cancel,
                       "Voice Control's first name is not the button's")
    }
}
