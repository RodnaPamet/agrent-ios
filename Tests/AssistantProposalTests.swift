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
    /// not read, or an activity with no kind.
    func testOnlyAFormThePhoneHasIsOffered() throws {
        XCTAssertNil(try proposal(#"{"kind":"journal-entry","draft":{"occurredOn":"2026-10-30"}}"#).entry(today: today))
        XCTAssertNil(try proposal(#"{"kind":"treatment","draft":"not an object"}"#).entry(today: today))
        XCTAssertNil(try proposal(#"{"kind":"activity","draft":{"occurredOn":"2026-10-30"}}"#).entry(today: today))
    }

    /// The answer carries it, and a halt after the answer keeps it.
    func testTheAnswerCarriesTheProposal() async throws {
        let answer = try JSONDecoder().decode(AssistantEvent.self, from: Data(#"""
        {"type":"answer","text":"Подготвих запис.","proposal":{"kind":"treatment","draft":{"kind":"SPRAY"}}}
        """#.utf8))
        guard case .answer(_, _, let proposal, _, _) = answer else { return XCTFail("not an answer") }
        XCTAssertEqual(proposal?.kind, "treatment")

        let store = AssistantStore { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(answer)
                continuation.yield(.halt(outcome: "ASSISTANT_TIME_BUDGET", message: nil))
                continuation.finish()
            }
        }
        store.draft = "Запиши пръскане"
        store.send(context: nil)
        await store.settled()
        guard case .answered(_, _, let note, let kept, _, _) = store.turns[0].phase else { return XCTFail("not answered") }
        XCTAssertNotNil(note)
        XCTAssertEqual(kept?.kind, "treatment")
    }

    func testTheWordsAreBulgarian() {
        XCTAssertTrue(UserMessage.isBulgarianSentence(AssistantText.preparedNote))
        XCTAssertTrue(AssistantText.openEntry.contains("Нов запис"))
    }

    // MARK: - An expense (owner, 2026-11-20: «the assistant should also be able to add expenses»)

    /// A cost draft opens the invoice review, one line filled, and never
    /// «Нов запис»: an expense is not a journal record.
    func testACostDraftFillsTheExpenseReview() throws {
        let p = try proposal(#"""
        {"kind":"cost","draft":{"category":"FUEL","amount":300.5,"incurredOn":"2026-10-30",
          "supplier":"Синтетичен доставчик","description":"Нафта за сеитбата","commodityCanonical":"wheat"}}
        """#)
        XCTAssertNil(p.entry(today: today), "an expense does not open «Нов запис»")
        let review = try XCTUnwrap(p.costReview(crops: [CropChoice(commodity: "wheat", areaDca: 1000)], today: today))
        XCTAssertNil(review.invoiceFileId, "no invoice behind a prepared expense")
        XCTAssertEqual(review.title, "Разход")
        XCTAssertEqual(review.checkFirstText, InvoiceReview.checkProposed)
        let row = try XCTUnwrap(review.rows.first)
        XCTAssertEqual(review.rows.count, 1)
        XCTAssertEqual(row.category, .fuel)
        XCTAssertEqual(row.amountText, "300,5")
        XCTAssertEqual(BgDate.isoDay(row.incurredOn), "2026-10-30")
        XCTAssertEqual(row.supplier, "Синтетичен доставчик")
        XCTAssertEqual(row.note, "Нафта за сеитбата")
        XCTAssertEqual(row.attribution, .crop("wheat"))
    }

    /// Booked as the review saves it: a total in euros, on the crop, and no
    /// invoice id — the same batch line an invoice row becomes, minus the file.
    func testACostDraftSavesAsOneBatchLine() throws {
        let review = try XCTUnwrap(proposal(#"""
        {"kind":"cost","draft":{"category":"FUEL","amount":300,"incurredOn":"2026-10-30"}}
        """#).costReview(crops: [], today: today))
        let sheet = try XCTUnwrap(review.sheet)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sheet)) as? [String: Any]
        let line = try XCTUnwrap((body?["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(line["category"] as? String, "FUEL")
        XCTAssertEqual(line["currency"] as? String, "EUR")
        XCTAssertEqual(line["allocationBasis"] as? String, "HOLDING", "no crop said: the whole farm")
        XCTAssertNil(line["invoiceFileId"])
        XCTAssertNil(line["commodityCanonical"])
    }

    /// What the farm does not grow starts as the whole farm, a future day as
    /// today, and a category this build does not know must be chosen — so the
    /// person sees each before «Запиши», never a guess.
    func testACostDraftNeverGuesses() throws {
        let review = try XCTUnwrap(proposal(#"""
        {"kind":"cost","draft":{"category":"SOMETHING_NEW","amount":10,"incurredOn":"2026-12-24","commodityCanonical":"rice"}}
        """#).costReview(crops: [CropChoice(commodity: "wheat", areaDca: 1000)], today: today))
        let row = try XCTUnwrap(review.rows.first)
        XCTAssertEqual(row.attribution, .farm)
        XCTAssertEqual(BgDate.isoDay(row.incurredOn), "2026-11-01")
        XCTAssertEqual(row.category, .unknown)
        XCTAssertNil(review.sheet, "an unknown category stops «Запиши» until the person picks one")
        // And a treatment is not an expense.
        XCTAssertNil(try proposal(#"{"kind":"treatment","draft":{"kind":"SPRAY"}}"#).costReview(today: today))
    }
}
