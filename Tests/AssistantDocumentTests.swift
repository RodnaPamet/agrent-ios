import XCTest
@testable import Agrent

/// A ДНЕВНИК offered by the assistant (#661, agri-saas#3158): the three
/// kinds read, anything else is no button and costs nothing else, and each
/// target reaches its own route.
@MainActor
final class AssistantDocumentTests: XCTestCase {

    private func answer(_ json: String) throws -> AssistantEvent {
        try JSONDecoder().decode(AssistantEvent.self, from: Data(json.utf8))
    }

    private func document(of event: AssistantEvent) -> AssistantDocument? {
        if case .answer(_, _, _, _, let document) = event { return document }
        return nil
    }

    func testTheThreeKindsRead() throws {
        let campaign = try answer(#"""
        {"type":"answer","text":"Ето дневника.","document":{"kind":"farm-campaign","label":"Дневник на стопанството 2025–2026","campaign":"2025-2026"}}
        """#)
        XCTAssertEqual(document(of: campaign),
                       AssistantDocument(label: "Дневник на стопанството 2025–2026",
                                         target: .campaign(FarmRecordAPI.Campaign(startYear: 2025))))

        let block = try answer(#"""
        {"type":"answer","text":"Ето.","document":{"kind":"block-register","label":"ДНЕВНИК за блок «Север», 01.03.2026 – 30.06.2026","locationId":"loc_1","from":"2026-03-01","to":"2026-06-30"}}
        """#)
        XCTAssertEqual(document(of: block)?.target, .block(locationID: "loc_1", from: "2026-03-01", to: "2026-06-30"))

        let treatment = try answer(#"""
        {"type":"answer","text":"Ето.","document":{"kind":"treatment","label":"ДНЕВНИК за третирането от 12.04.2026","treatmentGroupId":"tg_1"}}
        """#)
        XCTAssertEqual(document(of: treatment)?.target, .treatment(handle: "tg_1"))
    }

    func testAnOfferThePhoneCannotUseIsNoButtonButTheAnswerStays() throws {
        for broken in [
            #"{"kind":"everything","label":"Всичко"}"#,
            #"{"kind":"farm-campaign","label":"Х","campaign":"2025-2027"}"#,
            #"{"kind":"farm-campaign","label":"  ","campaign":"2025-2026"}"#,
            #"{"kind":"block-register","label":"Х","locationId":"loc_1","from":"вчера","to":"2026-06-30"}"#,
            #"{"kind":"treatment","label":"Х","treatmentGroupId":""}"#,
        ] {
            let event = try answer(#"{"type":"answer","text":"Да.","document":"# + broken + "}")
            guard case .answer(let text, _, _, _, let document) = event else { return XCTFail(broken) }
            XCTAssertEqual(text, "Да.", broken)
            XCTAssertNil(document, broken)
        }
        // No document at all is none, as before.
        XCTAssertNil(document(of: try answer(#"{"type":"answer","text":"Да."}"#)))
    }

    func testTheOfferSurvivesToTheAnsweredTurn() async throws {
        let offer = AssistantDocument(label: "Дневник на стопанството 2026–2027",
                                      target: .campaign(FarmRecordAPI.Campaign(startYear: 2026)))
        let store = AssistantStore { _ in
            AsyncThrowingStream { c in
                c.yield(.answer(text: "Ето.", links: [], proposal: nil, document: offer))
                c.yield(.done(truncatedAny: false))
                c.finish()
            }
        }
        store.draft = "Дай ми дневника"
        store.send(context: .surface(.tasks))
        await store.settled()
        guard case .answered(_, _, _, _, _, let kept) = store.turns[0].phase else { return XCTFail("not answered") }
        XCTAssertEqual(kept, offer)
    }

    func testTheBlockRegisterGoesToItsOwnRouteWithTheBlockInThePath() {
        XCTAssertTrue(AssistantDocumentAPI.blockRegisterPath("loc_1").hasSuffix("/locations/loc_1/farm-record"))
        XCTAssertFalse(AssistantDocumentAPI.blockRegisterPath("loc_1").contains("?"))
    }

    func testAnEmptyPeriodSaysSoInTheDiarysWords() {
        let empty = APIClient.APIError.http(status: 404, code: FarmRecordAPI.emptyPeriodCode, message: nil)
        let campaign = AssistantDocument(label: "Х", target: .campaign(FarmRecordAPI.Campaign(startYear: 2026)))
        let block = AssistantDocument(label: "Х", target: .block(locationID: "l", from: "2026-01-01", to: "2026-02-01"))
        XCTAssertEqual(AssistantDocumentAPI.failure(empty, for: campaign), FarmRecordAPI.emptyCampaignText)
        XCTAssertEqual(AssistantDocumentAPI.failure(empty, for: block), FarmRecordAPI.emptyPeriodText)
    }
}
