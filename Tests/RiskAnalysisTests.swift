import XCTest
@testable import Agrent

/// «Кратък анализ от асистента» on a parcel's «Риск» (owner, 2026-11-07):
/// the question the assistant is sent, built from what the history screen
/// holds. Nothing here calls the assistant.
@MainActor
final class RiskAnalysisTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testTheQuestionCarriesTheReadingsAndTheHistory() async throws {
        let risk = try await FarmRiskAPI.decodeAnalysis(from: fixture("risk-analysis-holes"))
        let history = try await ParcelHistoryAPI.decodeHistory(from: fixture("parcel-history"))
        let question = RiskAnalysisQuestion.text(
            parcel: history.parcel.name, risk: risk, freshness: .fresh,
            seasons: history.cropSeasons, operations: history.operations, weeds: history.weedObservations)
        XCTAssertTrue(question.hasPrefix("Направи кратък анализ (3–5 изречения) на риска за парцел «SYNTH-1»"), question)
        XCTAssertTrue(question.contains("Сателитни показатели: зеленина"), question)
        XCTAssertTrue(question.contains("Реколти: 2026, Пшеница, Добив 520 кг/дка"), question)
        XCTAssertTrue(question.contains("Последни дейности:"), question)
        XCTAssertTrue(question.contains("Последно наблюдение на плевели:"), question)
        XCTAssertTrue(question.hasSuffix("Каква може да е причината и какво да проверя на полето?"))
        XCTAssertFalse(question.contains("·"), "the eye's separator, not the sentence's")
        XCTAssertFalse(question.contains(".."), "a clause's own full stop doubled")
    }

    /// A parcel with no history yet is asked about by its readings alone.
    func testAnEmptyHistoryAsksAboutTheReadings() async throws {
        let risk = try await FarmRiskAPI.decodeAnalysis(from: fixture("risk-analysis-holes"))
        let question = RiskAnalysisQuestion.text(parcel: "SYNTH-1", risk: risk, freshness: nil,
                                                 seasons: [], operations: [], weeds: [])
        XCTAssertFalse(question.contains("Реколти:"))
        XCTAssertFalse(question.contains("Последни дейности:"))
        XCTAssertTrue(question.contains("Сателитни показатели:"))
    }
}
