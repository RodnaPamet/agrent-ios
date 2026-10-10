import XCTest
@testable import Agrent

/// What a failed «Запази» says about the books (#265): «НЕ е записан» only
/// when nothing can have been written, «може да е записан» otherwise.
final class CostSaveOutcomeTests: XCTestCase {

    private typealias Failure = NewCostView.Failure

    private func isNotSaved(_ failure: Failure) -> Bool {
        if case .notSaved = failure { true } else { false }
    }

    /// No signal, data off, a name that did not resolve, a refused connect:
    /// the request never left the phone, so the sheet stays editable.
    func testARequestThatNeverLeftThePhoneIsNotSaved() {
        let neverSent: [URLError.Code] = [
            .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
            .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        ]
        for code in neverSent {
            XCTAssertTrue(isNotSaved(Failure(URLError(code))), "\(code.rawValue) left the phone?")
        }
    }

    /// Once the body may have gone out, only the books can say. Includes the
    /// codes nobody has looked at, which the allow-list leaves unknown.
    func testALostAnswerStaysUnknown() {
        let mayHaveLanded: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .secureConnectionFailed,
            .serverCertificateUntrusted, .cancelled, .badServerResponse, .unknown,
        ]
        for code in mayHaveLanded {
            XCTAssertEqual(Failure(URLError(code)), .unknown(UserMessage.text(for: URLError(code))),
                           "\(code.rawValue) was called not saved")
        }
    }

    /// The server answered, so whatever it said, the row does not exist.
    func testAnAnswerIsNotSaved() {
        let refusal = APIClient.APIError.http(status: 400, code: nil, message: nil)
        XCTAssertEqual(Failure(refusal), .notSaved(UserMessage.text(for: refusal)))
    }

    /// The sentence is the one the rest of the app says for the same failure.
    func testTheMessageIsUserMessages() {
        XCTAssertEqual(Failure(URLError(.notConnectedToInternet)).message, "Няма интернет връзка.")
    }

    /// Both sides of the form sort a failure through `Failure.init`, and
    /// neither keeps a `URLError` rule of its own that would skip it.
    func testBothSavesUseTheOneRule() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Agrent/Calculator/NewCostView.swift"),
            encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "failure = Failure(error)").count - 1, 2,
                       "positive control: «Общи» and the crop side each classify through Failure")
        XCTAssertFalse(source.contains("catch let error as URLError"),
                       "a save sorts URLErrors itself again, past WriteOutcome")
    }
}
