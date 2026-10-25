import XCTest
@testable import Agrent

/// «Довърши мероприятието» and the unfinished row (owner, 2026-10-25;
/// agri-saas #2318). Nothing here reaches the server: every call is a
/// closure that records what it was asked.
final class TreatmentFinishTests: XCTestCase {

    private func definition(kind: String = "SPRAY", occurredOn: String? = "2026-09-16") -> TreatmentDefinition {
        TreatmentDefinition(
            treatmentGroupId: "tg_1", version: 2, kind: kind, occurredOn: occurredOn, title: "Препарат А",
            applicationTechnique: "boom", targetNote: "Плевели", productItemId: "itm_a", productName: "Препарат А",
            pppRegistrationNo: "0123", doseValue: Decimal(string: "0.15")!, doseUnitId: "u_l",
            doseUnitSymbol: "л/дка", waterRateValue: nil, waterRateUnitSymbol: nil,
            quarantinePeriodDays: 14, phenophase: "BBCH 31",
            lines: [.init(parcelId: "p1", parcelName: "Парцел 1", locationId: "b1", treatedAreaHa: 2.4),
                    .init(parcelId: "p2", parcelName: "Парцел 2", locationId: "b2", treatedAreaHa: nil)])
    }

    private func json(_ body: TreatmentAPI.Body) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    /// `RecordDiaryTreatment`'s properties as agri-saas main's spec lists them.
    private let specKeys: Set<String> = [
        "kind", "occurredOn", "parcelIds", "productItemId", "productName", "fertilizerItemId",
        "fertilizerName", "pppRegistrationNo", "quarantinePeriodDays", "newProductCategory",
        "targetNote", "doseValue", "doseUnitId", "applicationTechnique", "title", "phenophase", "parcels",
    ]

    // MARK: - The body that finishes it

    /// The treatment as the server holds it: every parcel, the product by
    /// id, the areas it kept, and nothing that would create a product.
    func testTheBodyIsTheTreatmentAsHeld() throws {
        let body = try json(try XCTUnwrap(TreatmentAPI.Body(resuming: definition())))
        XCTAssertTrue(Set(body.keys).isSubset(of: specKeys), body.keys.sorted().description)
        XCTAssertEqual(body["parcelIds"] as? [String], ["p1", "p2"], "pending lines included")
        XCTAssertEqual(body["productItemId"] as? String, "itm_a")
        XCTAssertNil(body["productName"], "by id or by name, never both")
        XCTAssertNil(body["pppRegistrationNo"], "an existing product's registration isn't sent")
        XCTAssertEqual(body["occurredOn"] as? String, "2026-09-16")
        XCTAssertEqual(body["title"] as? String, "Препарат А")
        XCTAssertEqual(body["quarantinePeriodDays"] as? Int, 14)
        XCTAssertEqual(body["phenophase"] as? String, "BBCH 31")
        let parcels = try XCTUnwrap(body["parcels"] as? [[String: Any]])
        XCTAssertEqual(parcels.map { $0["parcelId"] as? String }, ["p1"], "only the areas it has")
    }

    func testAFertilisingGoesByFertiliserID() throws {
        let body = try json(try XCTUnwrap(TreatmentAPI.Body(resuming: definition(kind: "FERTILIZE"))))
        XCTAssertEqual(body["fertilizerItemId"] as? String, "itm_a")
        XCTAssertNil(body["productItemId"])
    }

    /// No farm day: no line was ever marked, so nothing to finish from.
    func testNoDayNoBody() {
        XCTAssertNil(TreatmentAPI.Body(resuming: definition(occurredOn: nil)))
    }

    // MARK: - The action

    private actor Asked {
        var sent: [(TreatmentAPI.Body, String)] = []
        func record(_ body: TreatmentAPI.Body, _ key: String) { sent.append((body, key)) }
    }

    /// Sent under the treatment's own handle, which is what makes the server
    /// finish it rather than record a second one.
    func testItIsSentUnderItsOwnHandle() async {
        let asked = Asked()
        let definition = definition()
        let outcome = await TreatmentFinish.run("tg_1", calls: .init(
            definition: { _ in definition },
            send: { body, key in await asked.record(body, key) }))
        XCTAssertEqual(outcome, .finished)
        let sent = await asked.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.1, "tg_1")
        XCTAssertEqual(sent.first?.0.parcelIds, ["p1", "p2"])
    }

    func testARefusalIsSaid() async {
        let refused = APIClient.APIError.http(status: 403, code: "TREATMENT_EDIT_NOT_PERMITTED", message: nil)
        let outcome = await TreatmentFinish.run("tg_1", calls: .init(
            definition: { _ in throw refused },
            send: { _, _ in XCTFail("nothing is sent after a refused read") }))
        XCTAssertEqual(outcome, .failed(UserMessage.text(for: refused)))

        let noDay = definition(occurredOn: nil)
        let dayless = await TreatmentFinish.run("tg_1", calls: .init(
            definition: { _ in noDay },
            send: { _, _ in XCTFail("nothing is sent without a day") }))
        XCTAssertEqual(dayless, .failed(TreatmentFinish.noDay))
    }

    // MARK: - The row

    private func row(_ json: String) throws -> JournalTreatment {
        try JSONDecoder().decode(JournalTreatment.self, from: Data(json.utf8))
    }

    /// Unfinished on `pendingCount`, said with the server's own counts:
    /// `parcelCount` counts only the finished lines.
    func testAnUnfinishedRowSaysHowMuch() throws {
        let partial = try row(#"{"treatmentGroupId":"tg_1","parcelCount":2,"pendingCount":1,"lineCount":3}"#)
        XCTAssertEqual(partial.unfinishedText, "Записани 2 от 3 парцела. Останалите не са записани.")
        let done = try row(#"{"treatmentGroupId":"tg_1","parcelCount":3,"pendingCount":0,"lineCount":3}"#)
        XCTAssertNil(done.unfinishedText)
        let manual = try row(#"{"parcelCount":0,"pendingCount":0,"lineCount":0}"#)
        XCTAssertNil(manual.unfinishedText, "a manual entry is no unfinished treatment")
        let older = try row(#"{"treatmentGroupId":"tg_1","parcelCount":2}"#)
        XCTAssertNil(older.unfinishedText, "a server before #2318 says nothing")
    }
}
