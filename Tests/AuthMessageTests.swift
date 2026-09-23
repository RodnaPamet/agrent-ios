import XCTest
@testable import Agrent

/// Sign-in is the FIRST screen a farmer sees and the one most likely to
/// fail — no signal, or a misconfigured callback. It was also the last
/// screen still carrying both defects the rest of the app had fixed.
@MainActor
final class AuthMessageTests: XCTestCase {

    /// `AuthError.server` used to hold the raw response body, which
    /// `friendly` returned unchanged. A failed token exchange printed JSON
    /// at a farmer — the same defect `APIError.http` was restructured to
    /// remove, on the one screen that restructuring did not reach.
    func testAServerRefusalIsNotRawJSON() {
        let body = #"{"error":{"code":"invalid_grant","message":"Authorization code expired"}}"#
        let env = APIClient.envelope(from: Data(body.utf8))
        XCTAssertEqual(env?.code, "invalid_grant")

        let shown = UserMessage.httpText(status: 400, code: env?.code, message: env?.message)
        for fragment in ["{", "}", "\"", "error", "invalid_grant"] {
            XCTAssertFalse(shown.contains(fragment), "\(fragment) reached the screen: \(shown)")
        }
    }

    /// The other half: `error.localizedDescription` localises to the DEVICE
    /// locale, and this phone reports en-BG. That is the bug `UserMessage`
    /// exists for, and sign-in was still reading it.
    func testANetworkFailureIsBulgarianNotEnglish() {
        let text = UserMessage.text(for: URLError(.notConnectedToInternet))
        XCTAssertEqual(text, "Няма интернет връзка.")
        XCTAssertNotEqual(text, URLError(.notConnectedToInternet).localizedDescription)
        XCTAssertTrue(
            text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x400 },
            "not Cyrillic: \(text)")
    }

    /// An auth envelope with no recognisable code must still say something
    /// a person can act on, rather than falling through to an identifier.
    func testAnUncodedRefusalDegradesToTheStatusSentence() {
        let text = UserMessage.httpText(status: 503, code: nil, message: nil)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("503") && text.count < 12, "bare status: \(text)")
    }

    /// A bare identifier in `message` must never be rendered — the guard
    /// that catches it is `isHumanSentence`, and auth now goes through it
    /// like everything else.
    func testAnIdentifierInMessageIsNotShown() {
        let text = UserMessage.httpText(status: 400, code: nil, message: "INVALID_GRANT")
        XCTAssertFalse(text.contains("INVALID_GRANT"), text)
    }
}
