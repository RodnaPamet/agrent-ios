import XCTest
@testable import Agrent

/// The assistant's promotion block (#508, agri-saas #2665): beside the
/// answer, never inside it; the safety wording kept as its own value and
/// never defaulted. The promotions are synthetic.
@MainActor
final class AssistantPromotionTests: XCTestCase {

    private func event(_ json: String) throws -> AssistantEvent {
        try JSONDecoder().decode(AssistantEvent.self, from: Data(json.utf8))
    }

    private func promotions(_ event: AssistantEvent) -> [AssistantPromotion] {
        if case .answer(_, _, _, let promotions) = event { return promotions }
        return []
    }

    /// Each as its values; a ПРЗ's wording kept; none means none.
    func testPromotionsDecodeBesideTheAnswer() throws {
        let answer = try event("""
        {"type":"answer","text":"Пръскай при сухо време.","promotions":[
          {"id":"p1","company":"Синтетична химия АД","product":"Хербицид Пример","details":"  -15%  ",
           "validTo":"2026-11-29T22:00:00.000Z","safetyWording":"Използвайте продуктите за растителна защита безопасно."},
          {"id":"p2","company":"Синтетични семена ООД","product":"Пшеница","details":null,"validTo":null,"safetyWording":null},
          {"id":"p3","product":"без доставчик"}
        ]}
        """)
        let rows = promotions(answer)
        XCTAssertEqual(rows.map(\.id), ["p1", "p2"], "an unreadable promotion costs itself, never the answer")
        XCTAssertEqual(rows[0].details, "-15%")
        XCTAssertEqual(rows[0].safetyWording, "Използвайте продуктите за растителна защита безопасно.")
        XCTAssertNotNil(rows[0].validTo)
        XCTAssertNil(rows[1].safetyWording, "null is no wording applies, not an empty one")
        XCTAssertNil(rows[1].validTo, "an open campaign")
        if case .answer(let text, _, _, _) = answer { XCTAssertEqual(text, "Пръскай при сухо време.") }

        XCTAssertEqual(promotions(try event(#"{"type":"answer","text":"Без промоции."}"#)), [], "absent is none")
    }

    /// A wording that is there but not text drops the promotion: it is never
    /// shown without the wording it carries.
    func testAnUnreadableWordingDropsThePromotion() throws {
        let answer = try event("""
        {"type":"answer","text":"…","promotions":[
          {"id":"p1","company":"Синтетична химия АД","product":"Хербицид","safetyWording":42}]}
        """)
        XCTAssertEqual(promotions(answer), [])
    }

    /// One element for VoiceOver, starting «Промоция», on whose behalf, and
    /// the wording read in full.
    func testVoiceOverReadsItAsAPromotion() throws {
        let day = try XCTUnwrap(BgDate.parseISODay("2026-11-30"))
        let p = AssistantPromotion(id: "p1", company: "Синтетична химия АД", product: "Хербицид Пример",
                                   details: "-15%", validTo: day, safetyWording: "Използвайте безопасно.")
        XCTAssertTrue(p.spoken.hasPrefix("Промоция от Синтетична химия АД"), p.spoken)
        XCTAssertTrue(p.spoken.contains("Хербицид Пример"))
        XCTAssertTrue(p.spoken.contains("Използвайте безопасно."), "the wording is read too")
        let now = try XCTUnwrap(BgDate.parseISODay("2026-11-05"))
        XCTAssertEqual(AssistantPromotionText.until(day, now: now), "до \(BgDate.dayMonth(day))")
    }

    /// Kept through a halt that follows the answer, as the answer is.
    func testAHaltKeepsThePromotions() async {
        let promotion = AssistantPromotion(id: "p1", company: "Синтетични семена ООД", product: "Пшеница")
        let store = AssistantStore { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.answer(text: "Отговор.", links: [], proposal: nil, promotions: [promotion]))
                continuation.yield(.halt(outcome: "ASSISTANT_TIME_BUDGET", message: nil))
                continuation.yield(.done(truncatedAny: false))
                continuation.finish()
            }
        }
        store.draft = "Какво да сея?"
        store.send(context: nil)
        await store.settled()
        guard case .answered(_, _, let note, _, let promotions) = store.turns.first?.phase else {
            return XCTFail("no answer: \(String(describing: store.turns.first?.phase))")
        }
        XCTAssertNotNil(note)
        XCTAssertEqual(promotions, [promotion])
    }
}
