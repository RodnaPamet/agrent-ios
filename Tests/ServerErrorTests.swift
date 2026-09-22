import XCTest
@testable import Agrent

/// What an operator reads when the server refuses.
///
/// Before this, the whole JSON body went on screen inside one Bulgarian
/// sentence:
///
///     Грешка от сървъра (404): {"error":{"code":"NOT_FOUND",
///     "message":"Access review not found"}}
///
/// Braces, quotes and an English sentence, on a screen whose only actionable
/// question is whether to try again — with the server's own `code` sitting
/// inside that string, already decodable.
final class ServerErrorEnvelopeTests: XCTestCase {

    private func envelope(_ json: String) -> APIClient.ErrorEnvelope.Err? {
        APIClient.envelope(from: Data(json.utf8))
    }

    func testCodeAndMessageAreReadOffAnyStatus() {
        let e = envelope(#"{"error":{"code":"INVALID_PARCEL","message":"Parcel not found"}}"#)
        XCTAssertEqual(e?.code, "INVALID_PARCEL")
        XCTAssertEqual(e?.message, "Parcel not found")
    }

    /// The 409 path has parsed this shape against real responses since the
    /// optimistic-locking work. Generalising it must not break it.
    func testConflictDetailsStillDecode() {
        let e = envelope(#"""
        {"error":{"code":"STALE_DATA","message":"Changed","details":{"currentVersion":7,"expectedVersion":5}}}
        """#)
        XCTAssertEqual(e?.details?.currentVersion, 7)
        XCTAssertEqual(e?.details?.expectedVersion, 5)
    }

    /// A 404 once returned Next.js's 102,151-byte HTML error page. An error
    /// path that can itself fail is how that became a blank screen, so this
    /// returns nil rather than throwing — and, unlike the 300-character cap
    /// it replaces, no fragment of that HTML can reach a view at all.
    func testHTMLErrorPageYieldsNothingRatherThanAFragment() {
        XCTAssertNil(envelope("<!DOCTYPE html><html><body>500</body></html>"))
        XCTAssertNil(envelope(""))
        XCTAssertNil(envelope("null"))
    }

    func testWellFormedJSONWithoutAnErrorKeyIsNotAnError() {
        XCTAssertNil(envelope(#"{"rows":[]}"#))
    }
}

final class UserMessageHTTPTests: XCTestCase {

    /// A code this app knows beats everything else: written for an operator,
    /// by us, in their language.
    func testAKnownCodeWinsOverTheServersEnglish() {
        XCTAssertEqual(
            UserMessage.httpText(
                status: 400, code: "INVALID_PARCEL",
                message: "Parcel not found or belongs to a different tenant"
            ),
            "Парцелът не е намерен или принадлежи на друго стопанство."
        )
    }

    /// An unmapped code falls through to the server's sentence. The map is
    /// additive and ~500 messages are still uncoded, so this is the ordinary
    /// path, not a failure.
    func testAnUnknownCodeFallsBackToTheServersSentence() {
        XCTAssertEqual(
            UserMessage.httpText(
                status: 400, code: "SOME_FUTURE_CODE", message: "Delta must be non-zero."
            ),
            "Delta must be non-zero."
        )
    }

    /// The guard, and the defect behind it. Thirty call sites called
    /// `badRequest('INVALID_CROP_TYPE', 'Crop type not found…')` against a
    /// `(message, details)` signature, so a bare code travelled in the
    /// message field. Those are being fixed; this must hold for the NEXT
    /// thirty, which is a different claim and the one worth testing.
    func testABareCodeInTheMessageFieldNeverReachesTheOperator() {
        let text = UserMessage.httpText(
            status: 400, code: "BAD_REQUEST", message: "INVALID_CROP_TYPE"
        )
        XCTAssertEqual(text, "Заявката съдържа невалидни данни.")
        XCTAssertFalse(text.contains("INVALID_CROP_TYPE"))
        XCTAssertFalse(text.contains("_"))
    }

    func testIdentifierDetection() {
        XCTAssertFalse(UserMessage.isHumanSentence("INVALID_CROP_TYPE"))
        XCTAssertFalse(UserMessage.isHumanSentence("NOT_FOUND"))
        XCTAssertFalse(UserMessage.isHumanSentence("   "))
        XCTAssertFalse(UserMessage.isHumanSentence(""))
        // Real sentences, including a one-word one and a Cyrillic one.
        XCTAssertTrue(UserMessage.isHumanSentence("Crop type not found."))
        XCTAssertTrue(UserMessage.isHumanSentence("unauthorized"))
        XCTAssertTrue(UserMessage.isHumanSentence("Неуспешно"))
    }

    /// Structure is not prose, and the shouting check alone does not say so:
    /// `{"error":{"code":"NOT_FOUND"}}` has no spaces, and its lowercase
    /// letters make it differ from its own uppercasing, so it read as
    /// language. Found by this suite before the code shipped.
    func testSerialisedStructureIsNotASentence() {
        XCTAssertFalse(UserMessage.isHumanSentence(#"{"error":{"code":"NOT_FOUND"}}"#))
        XCTAssertFalse(UserMessage.isHumanSentence("<html><body>500</body></html>"))
        // Quotes alone are fine — this is a real sentence.
        XCTAssertTrue(UserMessage.isHumanSentence(#"Crop type "wheat" not found"#))
    }

    func testWithNoCodeAndNoBodyTheStatusCarriesIt() {
        XCTAssertEqual(
            UserMessage.httpText(status: 503, code: nil, message: nil),
            "Проблем със сървъра. Опитайте отново по-късно."
        )
        XCTAssertEqual(
            UserMessage.httpText(status: 403, code: nil, message: nil),
            "Нямате права за това действие."
        )
    }

    /// A 403 refuses identically every time. Telling someone to retry a
    /// permission failure wastes their time and their trust in the message,
    /// so only the statuses where retrying can actually work say so.
    func testOnlyRetryableStatusesSuggestRetrying() {
        for status in [400, 401, 403, 404, 413] {
            let text = UserMessage.statusText(status)
            XCTAssertFalse(
                text.lowercased().contains("опитайте"),
                "status \(status) suggests a retry that cannot succeed: \(text)"
            )
        }
        for status in [429, 500, 503] {
            XCTAssertTrue(
                UserMessage.statusText(status).lowercased().contains("опитайте"),
                "status \(status) is retryable and should say so"
            )
        }
    }

    /// No raw JSON, no braces, no English identifier — whatever the server
    /// sends. The old behaviour failed every one of these.
    func testNothingMachineReadableSurvivesToTheScreen() {
        let bodies: [(Int, String?, String?)] = [
            (404, "NOT_FOUND", #"{"error":{"code":"NOT_FOUND"}}"#),
            (400, "BAD_REQUEST", "INVALID_SEASON"),
            (500, nil, nil),
            (422, nil, "FILE_TOO_LARGE"),
        ]
        for (status, code, message) in bodies {
            let text = UserMessage.httpText(status: status, code: code, message: message)
            XCTAssertFalse(text.contains("{"), text)
            XCTAssertFalse(text.contains("\""), text)
            XCTAssertFalse(text.contains("_"), text)
            XCTAssertFalse(text.isEmpty)
        }
    }

    /// Every mapped string must be Bulgarian prose, not a pasted identifier
    /// and not English left in by accident. Cheap to assert across the whole
    /// table, and it is the kind of thing that rots one entry at a time as
    /// batches land.
    func testEveryMappedMessageIsBulgarianProse() {
        XCTAssertFalse(UserMessage.bulgarian.isEmpty)
        for (code, text) in UserMessage.bulgarian {
            XCTAssertFalse(text.contains("_"), "\(code) looks like an identifier")
            XCTAssertTrue(text.hasSuffix("."), "\(code) is not a sentence")
            XCTAssertTrue(
                text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x400 },
                "\(code) has no Cyrillic in it"
            )
        }
    }

    /// The error path itself must never be the thing that fails. This is the
    /// route a blank screen took once already.
    func testEveryStatusProducesSomethingReadable() {
        for status in [100, 204, 301, 400, 418, 451, 500, 599, 999] {
            XCTAssertFalse(UserMessage.statusText(status).isEmpty, "status \(status)")
        }
    }
}
