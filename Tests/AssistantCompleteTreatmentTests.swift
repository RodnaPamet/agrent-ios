import XCTest
@testable import Agrent

/// The whole treatment from the chat (#663, agri-saas#3162; owner
/// 2026-11-17): the field the server resolved and the unit as said, laid into
/// «Нов запис» for the person to check — never saved by the assistant.
@MainActor
final class AssistantCompleteTreatmentTests: XCTestCase {

    private func proposal(_ json: String) throws -> AssistantProposal {
        try JSONDecoder().decode(AssistantProposal.self, from: Data(json.utf8))
    }

    private func units() throws -> [Agrent.Unit] {
        try JSONDecoder().decode([Agrent.Unit].self, from: Data(#"""
        [{"id":"u1","key":"L_PER_DA","name":"литра на декар","symbol":"л/дка","measure":"RATE"},
         {"id":"u2","key":"KG_PER_DA","name":"килограма на декар","symbol":"кг/дка","measure":"RATE"}]
        """#.utf8))
    }

    private let today = BgDate.parseISODay("2026-11-17")!

    func testTheFieldAndUnitFromTheChatReachTheForm() throws {
        let entry = try XCTUnwrap(proposal(#"""
        {"kind":"treatment","draft":{"kind":"SPRAY","occurredOn":"2026-11-16","productName":"Децис",
          "doseValue":0.05,"targetNote":"листни въшки","doseUnitLabel":"л/дка",
          "chosenParcels":[{"id":"p1","label":"Север · Парцел 1","crop":"Wheat"},
                           {"id":"p2","label":"Север · Парцел 2","crop":"Wheat"}]}}
        """#).entry(today: today))
        XCTAssertEqual(entry.saidParcels, ["p1", "p2"])
        XCTAssertEqual(entry.saidCrop, "Wheat")
        XCTAssertEqual(entry.saidUnit, "л/дка")
        XCTAssertEqual(entry.productText, "Децис")
        XCTAssertNil(entry.doseUnit, "matched only once the catalogue is in hand")
    }

    func testAnOlderDraftWithoutThemStillOpensTheForm() throws {
        let entry = try XCTUnwrap(proposal(#"""
        {"kind":"treatment","draft":{"kind":"SPRAY","productName":"Децис"}}
        """#).entry(today: today))
        XCTAssertTrue(entry.saidParcels.isEmpty)
        XCTAssertNil(entry.saidCrop)
        XCTAssertNil(entry.saidUnit)
    }

    func testABrokenFieldListCostsTheFieldNotTheDraft() throws {
        let entry = try XCTUnwrap(proposal(#"""
        {"kind":"treatment","draft":{"kind":"SPRAY","productName":"Децис","chosenParcels":"Север"}}
        """#).entry(today: today))
        XCTAssertEqual(entry.productText, "Децис")
        XCTAssertTrue(entry.saidParcels.isEmpty)
    }

    func testTheSaidUnitMatchesTheCatalogueAndWinsOverTheProductDefault() throws {
        var draft = TreatmentDraft(date: today)
        draft.saidUnit = " КГ / ДКА "
        draft.applySaidUnit(units: try units())
        XCTAssertEqual(draft.doseUnit?.id, "u2")
        XCTAssertNil(draft.saidUnit, "applied once")
        // A later product default does not replace what was said.
        draft.prefill(from: .new, units: try units())
        XCTAssertEqual(draft.doseUnit?.id, "u2")
    }

    func testAnUnmatchedUnitIsLeftForThePersonNeverGuessed() throws {
        var draft = TreatmentDraft(date: today)
        draft.saidUnit = "чаши"
        draft.applySaidUnit(units: try units())
        XCTAssertNil(draft.doseUnit)
        // Before the catalogue loads nothing happens, and the word waits.
        var waiting = TreatmentDraft(date: today)
        waiting.saidUnit = "л/дка"
        waiting.applySaidUnit(units: [])
        XCTAssertEqual(waiting.saidUnit, "л/дка")
    }
}
