import AuthenticationServices
import XCTest
@testable import Agrent

/// The authenticator code after Sign in with Apple (agri-saas #1649,
/// agrent-ios#274). Nothing here reaches the server: the shapes, the
/// refusals' words and the screen's states are pure or driven directly.
@MainActor
final class AppleSecondFactorTests: XCTestCase {

    private func envelope(_ json: String) -> APIClient.ErrorEnvelope.Err? {
        APIClient.envelope(from: Data(json.utf8))
    }

    // MARK: - The two answers

    /// A 200 is the pair and a 202 the ticket, and neither body is read as
    /// the other: the `status` discriminant is checked, not trusted.
    func testA202IsATicketAndA200IsAGrant() throws {
        let grant = #"{"accessToken":"a","refreshToken":"r","tokenType":"Bearer","expiresIn":900,"refreshExpiresAt":"2026-11-08T00:00:00.000Z","termsPending":false}"#
        let ticket = #"{"status":"mfa_required","ticket":"t","expiresIn":300}"#

        guard case .granted(let granted) = try AppleSignIn.answer(status: 200, data: Data(grant.utf8)) else {
            return XCTFail("a 200 was not the pair")
        }
        XCTAssertEqual(granted.accessToken, "a")
        XCTAssertEqual(try AppleSignIn.answer(status: 202, data: Data(ticket.utf8)),
                       .codeRequired(.init(ticket: "t", expiresIn: 300)))

        XCTAssertThrowsError(try AppleSignIn.answer(status: 202, data: Data(grant.utf8)),
                             "a pair under 202 was read as a ticket")
        XCTAssertThrowsError(try AppleSignIn.answer(status: 200, data: Data(ticket.utf8)),
                             "a ticket under 200 was read as a pair")
        XCTAssertThrowsError(try AppleSignIn.answer(status: 202, data: Data(
            #"{"status":"something_else","ticket":"t","expiresIn":300}"#.utf8)),
                             "a 202 without the discriminant was read as a ticket")
        XCTAssertNil(try AppleSignIn.answer(status: 403, data: Data(#"{"error":{"code":"MFA_REQUIRED"}}"#.utf8)),
                     "a refusal is the caller's to read from the envelope")
    }

    /// The redemption carries the verifier under the server's spelling.
    func testTheCodeRequestCarriesTheVerifier() throws {
        let body = try JSONEncoder().encode(AppleSignIn.CodeRequest(ticket: "t", code: "123456", codeVerifier: "v"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["ticket": "t", "code": "123456", "code_verifier": "v"])
    }

    // MARK: - The refusals

    /// Each refusal of a code says what to do next, and only a ticket that
    /// no code can redeem ends the sign-in.
    func testEachRefusalOfACodeSaysWhatToDoNext() {
        func outcome(_ status: Int, _ json: String, expired: Bool = false) -> AppleSignIn.CodeOutcome {
            let env = envelope(json)
            return AppleSignIn.codeOutcome(status: status, code: env?.code, params: env?.params, expired: expired)
        }
        // `attemptsRemaining` arrives as an integer, in the real envelope.
        XCTAssertEqual(outcome(400, #"{"error":{"code":"MFA_CODE_INVALID","message":"Invalid code","params":{"attemptsRemaining":3}}}"#),
                       .again("Грешен код. Остават 3 опита."))
        XCTAssertEqual(outcome(400, #"{"error":{"code":"MFA_CODE_INVALID","params":{"attemptsRemaining":1}}}"#),
                       .again("Грешен код. Остава 1 опит."))
        XCTAssertEqual(outcome(400, #"{"error":{"code":"MFA_CODE_INVALID","params":{"attemptsRemaining":0}}}"#),
                       .restart(AppleSignIn.Text.tooManyWrong),
                       "the final miss burns the ticket in that response; asking again cannot help")
        XCTAssertEqual(outcome(400, #"{"error":{"code":"MFA_CODE_INVALID"}}"#),
                       .again(AppleSignIn.Text.wrongCodeAgain), "no count is still a wrong code, not a failure")
        XCTAssertEqual(outcome(400, #"{"error":{"code":"MFA_CODE_MALFORMED"}}"#), .again(AppleSignIn.Text.sixDigits))

        // One opaque code for every dead ticket; the phone's own clock tells
        // the one case worth its own words.
        XCTAssertEqual(outcome(403, #"{"error":{"code":"MFA_TICKET_INVALID"}}"#, expired: true),
                       .restart(AppleSignIn.Text.codeExpired))
        XCTAssertEqual(outcome(403, #"{"error":{"code":"MFA_TICKET_INVALID"}}"#),
                       .restart(AppleSignIn.Text.startAgain))

        // Not about the code: the ticket may still be good, unless its time
        // is up.
        XCTAssertEqual(outcome(429, #"{"error":{"code":"RATE_LIMITED"}}"#),
                       .again(UserMessage.httpText(status: 429, code: "RATE_LIMITED", message: nil)))
        XCTAssertEqual(outcome(500, "{}"), .again(UserMessage.httpText(status: 500, code: nil, message: nil)))
        XCTAssertEqual(outcome(500, "{}", expired: true), .restart(AppleSignIn.Text.codeExpired))

        for text in [AppleSignIn.Text.codeExplanation, AppleSignIn.Text.wrongCode(attemptsLeft: 2),
                     AppleSignIn.Text.wrongCodeAgain, AppleSignIn.Text.sixDigits, AppleSignIn.Text.tooManyWrong,
                     AppleSignIn.Text.codeExpired, AppleSignIn.Text.startAgain] {
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    /// Digits only, six at most: an autofilled or pasted code keeps its
    /// digits, and nothing else spends an attempt.
    func testTheFieldKeepsSixDigits() {
        XCTAssertEqual(AppleSignIn.digits("123 456"), "123456")
        XCTAssertEqual(AppleSignIn.digits("12-34-56-78"), "123456")
        XCTAssertEqual(AppleSignIn.digits("abc"), "")
        // Not every digit is an ASCII one, and the server takes only those.
        XCTAssertEqual(AppleSignIn.digits("١٢٣٤٥٦"), "")
    }

    // MARK: - The screen's states

    private func pending(expiresIn: TimeInterval) -> AppleSignIn.PendingCode {
        .init(ticket: "t", verifier: "v", deadline: Date().addingTimeInterval(expiresIn))
    }

    /// A ticket shows the code screen; going back drops it.
    func testATicketAsksForTheCodeAndBackDropsIt() {
        let auth = AuthClient()
        auth.awaitCode(pending(expiresIn: 300))
        XCTAssertEqual(auth.state, .codeRequired)
        auth.cancelCode()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(auth.codeError)
    }

    /// An expired ticket is not sent: the deadline is this phone's own, and
    /// the sign-in screen says why it is back.
    func testAnExpiredTicketIsNotSent() async {
        let auth = AuthClient()
        auth.awaitCode(pending(expiresIn: -1))
        await auth.submitCode("123456")
        XCTAssertEqual(auth.state, .failed(AppleSignIn.Text.codeExpired))
    }

    /// A straggling answer from Apple's sheet while the code is being asked
    /// for neither replaces the ticket nor ends the screen.
    func testAnAppleAnswerDoesNotInterruptTheCode() async {
        let auth = AuthClient()
        auth.awaitCode(pending(expiresIn: 300))
        await auth.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)))
        XCTAssertEqual(auth.state, .codeRequired)
    }

    /// Nothing to redeem, nothing sent: a submit outside the code screen is
    /// ignored.
    func testASubmitWithoutATicketDoesNothing() async {
        let auth = AuthClient()
        await auth.submitCode("123456")
        XCTAssertEqual(auth.state, .signedOut)
    }
}
