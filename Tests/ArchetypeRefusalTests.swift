import XCTest
@testable import Agrent

/// `markOperationParcel` now refuses to complete a line whose product is a
/// seeded archetype. It fires at COMPLETION, not at planning — the row can
/// be built against a placeholder and is refused when it becomes evidence.
@MainActor
final class ArchetypeRefusalTests: XCTestCase {

    private let envelope = """
    {"error":{"code":"PRODUCT_IS_SAMPLE_ARCHETYPE",
      "message":"\\"Generic Chlorothalonil 720 SC\\" is a sample product, not a registered one.",
      "params":{"product":"Generic Chlorothalonil 720 SC"}}}
    """

    func testParamsAreDecodedOffTheEnvelope() throws {
        let err = try XCTUnwrap(APIClient.envelope(from: Data(envelope.utf8)))
        XCTAssertEqual(err.code, "PRODUCT_IS_SAMPLE_ARCHETYPE")
        XCTAssertEqual(err.params?["product"], "Generic Chlorothalonil 720 SC")
    }

    /// The product is NAMED. Without it the sentence describes a category
    /// and leaves a farmer to work out which of their lines it means.
    func testTheRefusalNamesTheProduct() {
        let text = UserMessage.httpText(
            status: 400, code: "PRODUCT_IS_SAMPLE_ARCHETYPE",
            message: "\"Generic Chlorothalonil 720 SC\" is a sample product.",
            params: ["product": "Generic Chlorothalonil 720 SC"])
        XCTAssertTrue(text.contains("Generic Chlorothalonil 720 SC"), text)
        XCTAssertTrue(text.contains("образцов"), text)
        XCTAssertFalse(text.contains("sample product"), "the English leaked: \(text)")
    }

    /// The English here is a well-formed sentence, so `isHumanSentence`
    /// would happily render it. Only the code winning stops that — the
    /// same distinction `INVALID_TAB_ORDER` turned on.
    func testTheEnglishWouldOtherwiseHaveBeenShown() {
        let english = "\"Generic Chlorothalonil 720 SC\" is a sample product, not a registered one."
        XCTAssertTrue(UserMessage.isHumanSentence(english), "precondition")
        XCTAssertFalse(
            UserMessage.httpText(status: 400, code: "PRODUCT_IS_SAMPLE_ARCHETYPE",
                                 message: english, params: nil).contains("is a sample"))
    }

    /// Missing params must still produce a usable sentence. A refusal that
    /// degrades to nothing is worse than one that degrades to less.
    func testItDegradesWithoutParams() {
        let text = UserMessage.httpText(status: 400, code: "PRODUCT_IS_SAMPLE_ARCHETYPE",
                                        message: nil, params: nil)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("образцов"), text)
    }

    /// The app blocks this before sending, so reaching it means the client
    /// and server rules have drifted. It still has to read as Bulgarian.
    func testTheRegulatoryFieldsRefusalIsTranslated() {
        let text = UserMessage.httpText(
            status: 400, code: "PESTICIDE_REGULATORY_FIELDS_REQUIRED",
            message: "pppRegistrationNo and quarantinePeriodDays are required",
            params: ["missing": "pppRegistrationNo, quarantinePeriodDays"])
        XCTAssertTrue(text.contains("пppRegistrationNo") || text.contains("pppRegistrationNo"))
        XCTAssertTrue(text.contains("препарат за РЗ"), text)
    }

    /// NOT every param gets quoted. `INVALID_TAB_ORDER` carries
    /// `params.max` = "12" and the message ignores it, because twelve is a
    /// payload bound the farmer is not subject to — the editor stops at
    /// five. The test is whether the value is what stopped THEM.
    func testAParameterTheUserIsNotSubjectToIsStillNotQuoted() {
        let text = UserMessage.httpText(
            status: 400, code: "INVALID_TAB_ORDER",
            message: "order must be an array of up to 12 unique non-empty ids.",
            params: ["max": "12"])
        XCTAssertFalse(text.contains("12"), text)
        XCTAssertEqual(text, "Подредбата на разделите не беше приета.")
    }

    /// An unknown code with params must not start inventing sentences.
    func testAnUnknownCodeIgnoresParamsAndFallsBack() {
        XCTAssertEqual(
            UserMessage.httpText(status: 400, code: "SOMETHING_NEW",
                                 message: "Something specific happened.",
                                 params: ["thing": "x"]),
            "Something specific happened.")
    }
}
