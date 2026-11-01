import XCTest
@testable import Agrent

/// A change the assistant prepared (#483 phase 2, agri-saas #2636): its
/// draft decoded and laid into «Нов запис» for the person to check and send.
/// Nothing here posts.
@MainActor
final class AssistantProposalTests: XCTestCase {

    private func proposal(_ json: String) throws -> AssistantProposal {
        try JSONDecoder().decode(AssistantProposal.self, from: Data(json.utf8))
    }

    private let today = BgDate.parseISODay("2026-11-01")!

    /// The human-readable fields of `POST /journal/treatments`, each into
    /// the form's own field; no id, no unit, no parcels.
    func testATreatmentDraftFillsTheForm() throws {
        let entry = try XCTUnwrap(proposal(#"""
        {"kind":"treatment","draft":{"kind":"FERTILIZE","occurredOn":"2026-10-30",
          "fertilizerName":"Амониева селитра","doseValue":25.5,"targetNote":"",
          "phenophase":"BBCH 21","quarantinePeriodDays":0,"applicationTechnique":"SPREADER"}}
        """#).entry(today: today))
        XCTAssertEqual(entry.kind, .fertilize)
        XCTAssertNil(entry.activity)
        XCTAssertEqual(BgDate.isoDay(entry.date), "2026-10-30")
        XCTAssertEqual(entry.productText, "Амониева селитра")
        XCTAssertEqual(entry.doseText, "25,5")
        XCTAssertEqual(entry.phenophaseText, "BBCH 21")
        XCTAssertEqual(entry.quarantineText, "0")
        XCTAssertEqual(entry.technique, .spreader)
        XCTAssertNil(entry.doseUnit, "the unit is the person's to pick")
    }

    func testAnActivityDraftFillsTheForm() throws {
        let entry = try XCTUnwrap(proposal(#"""
        {"kind":"activity","draft":{"kind":"HARVEST","occurredOn":"2026-10-29","harvestKg":12500}}
        """#).entry(today: today))
        XCTAssertEqual(entry.activity, .harvest)
        XCTAssertEqual(entry.harvestText, "12500")
        XCTAssertEqual(BgDate.isoDay(entry.date), "2026-10-29")
    }

    /// Done work only: a draft dated ahead is today, as the date picker is.
    func testADraftIsNeverInTheFuture() throws {
        let entry = try XCTUnwrap(proposal(#"""
        {"kind":"treatment","draft":{"kind":"SPRAY","occurredOn":"2026-12-24","productName":"Синтетичен препарат"}}
        """#).entry(today: today))
        XCTAssertEqual(BgDate.isoDay(entry.date), "2026-11-01")
        XCTAssertEqual(entry.kind, .spray)
    }

    /// Nothing to open: a kind this phone has no form for, a draft that does
    /// not read, an activity with no kind, or one the server held back.
    func testOnlyAFormThePhoneHasIsOffered() throws {
        XCTAssertNil(try proposal(#"{"kind":"journal-entry","draft":{"title":"x"}}"#).entry(today: today))
        XCTAssertNil(try proposal(#"{"kind":"treatment","draft":"not an object"}"#).entry(today: today))
        XCTAssertNil(try proposal(#"{"kind":"activity","draft":{"occurredOn":"2026-10-30"}}"#).entry(today: today))
        XCTAssertNil(try proposal(#"{"kind":"treatment","status":"QUARANTINED","draft":{"kind":"SPRAY"}}"#)
            .entry(today: today))
    }

    /// The answer carries it, and a halt after the answer keeps it.
    func testTheAnswerCarriesTheProposal() async throws {
        let answer = try JSONDecoder().decode(AssistantEvent.self, from: Data(#"""
        {"type":"answer","text":"Подготвих запис.","proposal":{"kind":"treatment","draft":{"kind":"SPRAY"}}}
        """#.utf8))
        guard case .answer(_, _, let proposal) = answer else { return XCTFail("not an answer") }
        XCTAssertEqual(proposal?.kind, "treatment")

        let store = AssistantStore { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(answer)
                continuation.yield(.halt(outcome: "ASSISTANT_TIME_BUDGET", message: nil, counts: [:]))
                continuation.finish()
            }
        }
        store.draft = "Запиши пръскане"
        store.send(context: nil)
        await store.settled()
        guard case .answered(_, _, let note, let kept) = store.turns[0].phase else { return XCTFail("not answered") }
        XCTAssertNotNil(note)
        XCTAssertEqual(kept?.kind, "treatment")
    }

    func testTheWordsAreBulgarian() {
        XCTAssertTrue(UserMessage.isBulgarianSentence(AssistantText.preparedNote))
        XCTAssertTrue(AssistantText.openEntry.contains("Нов запис"))
    }
}
