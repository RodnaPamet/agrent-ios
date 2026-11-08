import SwiftUI

/// «Анализ на риска» (owner, 2026-11-07: "risk section in history should
/// also include short analysis on click", the assistant's analysis): the
/// assistant's own sheet, with a question about this parcel already sent,
/// so the answer arrives as the sheet opens and the person can ask on.
///
/// ── What the assistant is told ──
///
/// Its tools read blocks, journal entries, tasks and prices, not a parcel's
/// archive, so the question carries what this screen already holds: the
/// readings as Риск says them, the crop and area, the last seasons with
/// their yields, the last operations and the weeds last seen
/// (`RiskAnalysisQuestion`). The page is the parcel's own template, with its
/// id (agri-saas's `PAGE_ROUTE_TEMPLATE_SET` has it), so the assistant knows
/// which field it is about.
struct RiskAnalysisSheet: View {
    let parcelID: String
    let question: String
    /// A prepared entry chosen in the sheet, as the assistant's button has.
    var open: (TreatmentDraft) -> Void = { _ in }

    @State private var store = AssistantStore()
    @State private var asked = false

    var body: some View {
        AssistantSheet(store: store, context: Self.context(parcelID), open: open)
            .task {
                guard !asked else { return }
                asked = true
                store.draft = question
                store.send(context: Self.context(parcelID))
            }
    }

    nonisolated static func context(_ parcelID: String) -> AssistantPageContext {
        AssistantPageContext(route: "/t/[tenantSlug]/parcels/[parcelId]", selectedIds: [parcelID])
    }
}

/// The question, from what the history screen holds. Pure, so tests pin it.
@MainActor
enum RiskAnalysisQuestion {
    static func text(parcel: String, risk: ParcelRisk, freshness: Freshness?, trend: String? = nil,
                     rain: String? = nil,
                     seasons: [CropSeason], operations: [ParcelHistoryOperation],
                     weeds: [WeedObservation]) -> String {
        var facts: [String] = []
        let readings = ParcelRiskReadings.spoken(risk, freshness).compactMap { $0 }.joined(separator: "; ")
        facts.append("Сателитни показатели: \(readings).")
        // How even the field is (#562 stage 2), said as over the visible part.
        if let field = risk.withinField, let spread = RiskWithinField.facts(field) { facts.append(spread) }
        // The rain since the picture (owner, 2026-11-08), and what «влага»
        // measures, so the answer does not call a soaked bare field dry.
        if let rain { facts.append(rain) }
        facts.append(RiskExplanation.moistureNote)
        // The period on screen (#562), so the answer speaks to the same days.
        if let trend { facts.append(trend) }
        let about = [CommodityName.freeText(risk.cropType), risk.areaHa.map { "\(Num.text($0 * 10)) дка" }]
            .compactMap { $0 }.joined(separator: ", ")
        if !seasons.isEmpty {
            facts.append("Реколти: " + seasons.prefix(3).map { Self.clause($0.historyLine) }.joined(separator: "; ") + ".")
        }
        if !operations.isEmpty {
            facts.append("Последни дейности: " + operations.prefix(3).map { Self.clause($0.historyLine) }.joined(separator: "; ") + ".")
        }
        if let walk = weeds.first {
            facts.append("Последно наблюдение на плевели: \(Self.clause(walk.historyLine)).")
        }
        let head = "Направи кратък анализ (3–5 изречения) на риска за парцел «\(parcel)»"
            + (about.isEmpty ? "" : " (\(about))") + "."
        return ([head] + facts + ["Каква може да е причината и какво да проверя на полето?"]).joined(separator: " ")
    }

    /// A row's spoken form inside the sentence, without its full stop.
    private static func clause(_ line: ParcelHistoryLine) -> String {
        var text = line.spoken
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
