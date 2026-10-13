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

    /// The code's sentence beats even a BULGARIAN message: it is written
    /// for this screen. (An English one falls away by itself since the
    /// owner's Bulgarian-only rule, so it would prove nothing here.)
    func testTheCodeBeatsTheServersMessage() {
        let server = "Продуктът е образец."
        XCTAssertTrue(UserMessage.isBulgarianSentence(server), "precondition")
        XCTAssertNotEqual(
            UserMessage.httpText(status: 400, code: "PRODUCT_IS_SAMPLE_ARCHETYPE",
                                 message: server, params: nil), server)
    }

    /// Missing params must still produce a usable sentence. A refusal that
    /// degrades to nothing is worse than one that degrades to less.
    func testItDegradesWithoutParams() {
        let text = UserMessage.httpText(status: 400, code: "PRODUCT_IS_SAMPLE_ARCHETYPE",
                                        message: nil, params: nil)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("образцов"), text)
    }

    /// The spray sheet asks for both whenever a typed product is new (#237),
    /// so reaching this means its match and the server's drifted. It still
    /// reads as Bulgarian: the WIRE names in `params.missing` are named in
    /// the sheet's words — this test used to pin them quoted raw.
    func testTheRegulatoryFieldsRefusalIsTranslated() {
        let text = UserMessage.httpText(
            status: 400, code: "PESTICIDE_REGULATORY_FIELDS_REQUIRED",
            message: "pppRegistrationNo and quarantinePeriodDays are required",
            params: ["missing": "pppRegistrationNo, quarantinePeriodDays"])
        XCTAssertEqual(text, "Липсва за нов препарат: рег. № по ЗЗР и карантинен срок.")
        XCTAssertFalse(text.contains("ppp"), text)
        // The shape the server actually sends (`catalog.ts`): joined with a
        // bare comma, wire names, in that order.
        XCTAssertEqual(UserMessage.httpText(status: 400, code: "PESTICIDE_REGULATORY_FIELDS_REQUIRED",
                                            message: nil,
                                            params: ["missing": "pppRegistrationNo,quarantinePeriodDays"]),
                       "Липсва за нов препарат: рег. № по ЗЗР и карантинен срок.")
        XCTAssertEqual(UserMessage.httpText(status: 400, code: "PESTICIDE_REGULATORY_FIELDS_REQUIRED",
                                            message: nil, params: ["missing": "quarantinePeriodDays"]),
                       "Липсва за нов препарат: карантинен срок.")
        // A name this build does not know: the general sentence, never the code.
        XCTAssertEqual(UserMessage.httpText(status: 400, code: "PESTICIDE_REGULATORY_FIELDS_REQUIRED",
                                            message: nil, params: ["missing": "activeIngredient"]),
                       "За нов препарат са задължителни рег. № по ЗЗР и карантинен срок.")
    }

    /// The typed product's other refusals (agri-saas #1499) read as Bulgarian.
    func testTheTypedProductRefusalsAreTranslated() {
        for code in ["PRODUCT_NAME_REQUIRED", "DOSE_UNIT_HAS_NO_BASE", "FERTILIZER_EXPECTED",
                     "OPERATION_INPUT_AMBIGUOUS"] {
            // A Bulgarian placeholder, and the generic 400 ruled out: an
            // English one would fall to the status line with or without a
            // sentence of ours, and prove nothing.
            let placeholder = "Сървърът каза нещо."
            let text = UserMessage.httpText(status: 400, code: code, message: placeholder)
            XCTAssertNotEqual(text, placeholder, code)
            XCTAssertNotEqual(text, UserMessage.statusText(400), code)
        }
        XCTAssertNil(UserMessage.bulgarian["PRODUCT_EXPECTED"], "the server dropped it; so do we")
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
                                 message: "Случи се нещо конкретно.",
                                 params: ["thing": "x"]),
            "Случи се нещо конкретно.")
    }
}
