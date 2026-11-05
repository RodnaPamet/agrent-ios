import XCTest
@testable import Agrent

/// The superuser's «Промоции» console (#529, agri-saas #2749). Nothing here
/// reaches the server: every write is outward-facing and only built.
@MainActor
final class AdminPromotionsTests: XCTestCase {

    private func promotion(_ fields: String) throws -> AdminPromotionsAPI.Promotion {
        try JSONDecoder().decode(AdminPromotionsAPI.Promotion.self, from: Data("""
        {"id":"p1","companyId":"c1","companyName":"Синтетични семена ООД","title":"Пшеница","body":null,
         "mediaUrl":null,"category":"seeds","ctaUrl":null,"pppRegistrationNo":null,"leadCount":0,\(fields)}
        """.utf8))
    }

    /// The window read either way: instants today, day keys after the
    /// follow-up (agreed 2026-11-05). The status is the server's own.
    func testThePromotionReadsBothDateShapes() throws {
        let instant = try promotion(#""publishedAt":null,"validFrom":"2026-11-01T22:00:00.000Z","validTo":"2026-11-29T22:00:00.000Z","status":"DRAFT""#)
        let days = try promotion(#""publishedAt":"2026-11-03T08:00:00.000Z","validFrom":"2026-11-02","validTo":"2026-11-30","status":"LIVE""#)
        XCTAssertEqual(instant.status, .draft)
        XCTAssertFalse(instant.isPublished)
        XCTAssertEqual(days.status, .live)
        XCTAssertTrue(days.isPublished)
        XCTAssertEqual(days.validTo.map(BgDate.isoDay), "2026-11-30")
        XCTAssertNotNil(instant.validFrom)
        XCTAssertEqual(AdminPromotionsAPI.Status.scheduled.label, "Насрочена")
        let odd = try promotion(#""publishedAt":null,"validFrom":null,"validTo":null,"status":"ARCHIVED""#)
        XCTAssertEqual(odd.status, .unknown, "a status this build does not know costs the label, not the row")
    }

    private func json(_ payload: AdminPromotionsAPI.Payload) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    }

    /// An omitted ПРЗ number keeps the classification; null clears it. So
    /// an edit that did not touch it never sends it, and fixing a title
    /// cannot declassify a pesticide.
    func testThePPPNumberTravelsOnlyWhenChanged() throws {
        var draft = AdminPromotionsAPI.Draft()
        draft.companyId = "c1"
        draft.title = "Хербицид"
        draft.pppRegistrationNo = "0123-ППП"
        let untouched = try json(draft.payload(creating: false))
        XCTAssertNil(untouched["pppRegistrationNo"], "omitted on an edit that did not change it")
        XCTAssertFalse(untouched.keys.contains("pppRegistrationNo"))

        draft.pppChanged = true
        XCTAssertEqual(try json(draft.payload(creating: false))["pppRegistrationNo"] as? String, "0123-ППП")
        draft.pppRegistrationNo = ""
        let cleared = try json(draft.payload(creating: false))
        XCTAssertTrue(cleared.keys.contains("pppRegistrationNo"))
        XCTAssertTrue(cleared["pppRegistrationNo"] is NSNull, "explicit null: no longer a ПРЗ")

        var fresh = AdminPromotionsAPI.Draft()
        fresh.companyName = " Нова фирма "
        fresh.title = "Т"
        let created = try json(fresh.payload(creating: true))
        XCTAssertEqual(created["companyName"] as? String, "Нова фирма")
        XCTAssertNil(created["companyId"])
        XCTAssertTrue(created.keys.contains("pppRegistrationNo"), "a create says it either way")
    }

    /// Days go as day keys, `validTo` inclusive: the farm's day is made on
    /// the server, once.
    func testDaysTravelAsDayKeys() throws {
        var draft = AdminPromotionsAPI.Draft()
        draft.companyId = "c1"
        draft.title = "Т"
        draft.validFrom = BgDate.parseISODay("2026-11-02")
        draft.validTo = BgDate.parseISODay("2026-11-30")
        let body = try json(draft.payload(creating: true))
        XCTAssertEqual(body["validFrom"] as? String, "2026-11-02")
        XCTAssertEqual(body["validTo"] as? String, "2026-11-30")
        XCTAssertTrue(draft.canSave)
        draft.validTo = BgDate.parseISODay("2026-11-01")
        XCTAssertFalse(draft.canSave, "an inverted window is refused before it is sent")
        draft.validTo = nil
        draft.title = "  "
        XCTAssertFalse(draft.canSave, "no title")
    }

    /// A leaflet's proposal as a draft: the price as printed, nothing
    /// guessed, the supplier as read and matched as the server matches.
    func testAProposalBecomesADraft() {
        let offer = AdminPromotionsAPI.LeafletScan.Offer(productName: "Амониева селитра", priceText: "от 1 200 лв./т",
                                                         validityText: "до изчерпване", note: nil)
        let draft = AdminLeafletScanView.draft(offer, company: "Примерен тор АД")
        XCTAssertEqual(draft.title, "Амониева селитра")
        XCTAssertEqual(draft.body, "от 1 200 лв./т\nдо изчерпване")
        XCTAssertEqual(draft.companyName, "Примерен тор АД")
        XCTAssertNil(draft.validTo, "a validity in words stays words")
        XCTAssertEqual(AdminPromotionEditor.nameKey("  Примерен   ТОР ад "), "примерен тор ад")
    }

    func testThePathsAreTheConsoles() {
        XCTAssertTrue(AdminPromotionsAPI.listPath.hasSuffix("/admin/promotions"))
        XCTAssertTrue(AdminPromotionsAPI.imagePath("p 1").hasSuffix("/admin/promotions/p%201/image"))
        XCTAssertTrue(AdminPromotionsAPI.leafletScanPath.hasSuffix("/admin/promotions/leaflet-scan"))
        XCTAssertTrue(AdminPromotionsAPI.companyPath("c1").hasSuffix("/admin/companies/c1"))
        XCTAssertEqual(UserMessage.text(for: APIClient.APIError.http(status: 409, code: "COMPANY_NAME_TAKEN", message: nil)),
                       "Вече има доставчик с това име.")
    }
}
