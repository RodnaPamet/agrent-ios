import XCTest
@testable import Agrent

/// «Промоции» (#528, agri-saas #2725). Nothing here reaches the server, and
/// nothing sends a request to a supplier: the lead is outward-facing, so it
/// is only built and decoded here. The offers are synthetic.
@MainActor
final class PromotionsTests: XCTestCase {

    private func list(_ json: String) async throws -> [PromotionsAPI.Promotion] {
        try await PromotionsAPI.decodeList(from: Data(json.utf8))
    }

    /// The agreed shape: an envelope; a day as a day; the five kinds and
    /// «Друго» for any other; a promotion that does not read costs only
    /// itself.
    func testTheListDecodes() async throws {
        let rows = try await list("""
        {"offers":[
          {"id":"p1","company":"Синтетични семена ООД","title":"Пшеница","body":"  Елит  ","category":"seeds",
           "mediaUrl":"/api/promotions/p1/image","ctaUrl":"https://example.invalid/a",
           "validFrom":"2026-11-01","validTo":"2026-11-30","hasRequested":true},
          {"id":"p2","company":"Примерен тор АД","title":"Селитра","category":"fertilizer","hasRequested":false},
          {"id":"p3","company":"Тестова услуга ЕООД","title":"Анализ","category":"drones"},
          {"id":"p4","title":"без доставчик"}
        ]}
        """)
        XCTAssertEqual(rows.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(rows[0].body, "Елит")
        XCTAssertEqual(rows[0].category, .seeds)
        XCTAssertEqual(rows[0].mediaUrl, "/api/promotions/p1/image")
        XCTAssertEqual(rows[0].ctaUrl?.absoluteString, "https://example.invalid/a")
        XCTAssertTrue(rows[0].hasRequested)
        XCTAssertEqual(rows[0].validTo.map(BgDate.isoDay), "2026-11-30", "the farm's day, read as a day")
        XCTAssertNil(rows[1].mediaUrl)
        XCTAssertFalse(rows[1].hasRequested)
        XCTAssertEqual(rows[2].category, .other)
        XCTAssertEqual(rows[2].category.label, "Друго")
    }

    /// The person's bearer goes only to app.agrent.bg's own picture route:
    /// any other `mediaUrl` is not fetched; a link Safari's view would not
    /// open is not offered.
    func testOnlyTheServersOwnPictureIsFetched() async throws {
        let rows = try await list("""
        {"offers":[
          {"id":"p1","company":"C","title":"T","category":"seeds","mediaUrl":"https://cdn.example.invalid/p1.jpg",
           "ctaUrl":"javascript:alert(1)"},
          {"id":"p2","company":"C","title":"T","category":"seeds","mediaUrl":"/api/promotions/p9/image"}
        ]}
        """)
        XCTAssertNil(rows[0].mediaUrl, "off-site")
        XCTAssertNil(rows[0].ctaUrl, "not a web page")
        XCTAssertNil(rows[1].mediaUrl, "another promotion's picture")
        XCTAssertEqual(PromotionsAPI.imagePath("a b"), "/api/promotions/a%20b/image")
    }

    func testThePathsAreTheFarms() {
        XCTAssertTrue(PromotionsAPI.listPath.hasSuffix("/offers"))
        XCTAssertTrue(PromotionsAPI.leadsPath.hasSuffix("/offers/leads"))
        XCTAssertEqual(AppSurface.promotions.rawValue, "/offers")
        XCTAssertEqual(AppSurface.promotions.label, "Промоции")
        XCTAssertFalse(AppSurface.promotions.isOperatorAllowed, "not on a mechanisator's one screen")
        XCTAssertFalse(AppSurface.fallback.contains(.promotions), "in the menu by default, not the bar")
    }

    /// The server's three answers a request can meet, each with its own
    /// way out: asked already counts as asked; a stale card says the offer
    /// ended and the list is read again.
    func testTheRefusalsAreReadAsTheyMean() {
        let already = APIClient.APIError.http(status: 409, code: "PROMOTION_LEAD_ALREADY_SENT", message: nil)
        let ended = APIClient.APIError.http(status: 404, code: "PROMOTION_NOT_AVAILABLE", message: nil)
        let gone = APIClient.APIError.http(status: 404, code: "PROMOTION_NOT_FOUND", message: nil)
        let forbidden = APIClient.APIError.http(status: 403, code: "WRITE_FORBIDDEN_FOR_ROLE", message: nil)
        XCTAssertTrue(PromotionsAPI.isAlreadySent(already))
        XCTAssertFalse(PromotionsAPI.isAlreadySent(ended))
        XCTAssertTrue(PromotionsAPI.isNoLongerRunning(ended))
        XCTAssertTrue(PromotionsAPI.isNoLongerRunning(gone))
        XCTAssertFalse(PromotionsAPI.isNoLongerRunning(forbidden))
        XCTAssertEqual(UserMessage.text(for: already), "Вече сте поискали оферта за тази промоция.")
        XCTAssertEqual(UserMessage.text(for: ended), PromotionsText.ended)
        XCTAssertTrue(PromotionsText.ended.contains("още да не е започнала"), "true of a campaign not yet open too")
    }

    /// The request carries the person's consent as `true` and nothing else
    /// that names them: the server takes who from the session.
    func testTheRequestBodyIsTheContract() throws {
        struct Probe: Encodable { let promotionId: String; let message: String; let consent: Bool }
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            Probe(promotionId: "p1", message: "Колко струва?", consent: true))) as? [String: Any]
        XCTAssertEqual(Set(body?.keys ?? [:].keys), ["promotionId", "message", "consent"])
        XCTAssertEqual(PromotionsAPI.maxMessage, 2000)
        // The real body is private to the API; its keys are read from source.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Agrent/Promotions/PromotionsAPI.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Lead(promotionId: promotionId, message: message, consent: true)"))
    }

    /// Asked: the card says so at once.
    func testMarkingRequestedChangesOnlyThatCard() async throws {
        let store = PromotionsStore()
        XCTAssertNil(store.state.value)
        store.markRequested("p1")
        XCTAssertNil(store.state.value, "nothing loaded, nothing marked")
    }

    /// «Валидна до 30 ноември», and the year when it is not this one.
    func testUntilWhenReadsAsADay() throws {
        let day = try XCTUnwrap(BgDate.parseISODay("2026-11-30"))
        let now = try XCTUnwrap(BgDate.parseISODay("2026-11-05"))
        XCTAssertEqual(PromotionsText.validUntil(day, now: now), "Валидна до \(BgDate.dayMonth(day))")
        let next = try XCTUnwrap(BgDate.parseISODay("2027-01-31"))
        XCTAssertEqual(PromotionsText.validUntil(next, now: now), "Валидна до \(BgDate.full(next))")
    }

    /// The consent is the person's own tick, in the web's words, naming the
    /// supplier it goes to.
    func testTheConsentNamesTheSupplier() {
        XCTAssertEqual(PromotionLeadText.consent("Синтетични семена ООД"),
                       "Съгласен съм името и съобщението ми да бъдат споделени с Синтетични семена ООД, "
                       + "за да се свържат с мен относно тази оферта.")
    }
}
