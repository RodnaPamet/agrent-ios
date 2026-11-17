import Foundation
import Observation

/// National average yields and coupled-support rates (#638), from
/// `GET /api/agro-benchmarks` (agri-saas, person-scoped like the calendar,
/// no flag: on for everyone, owner 2026-11-17).
///
/// Yields arrive as МЗХ prints them, kg/ha; the phone shows kg/дка, which is
/// the hectare figure over 10 — exact, not a conversion. Rates arrive in the
/// order's own leva AND as euro cents per дка the server converted; only the
/// euro is shown, under the vine card's marker (owner, 2026-11-17: "convert,
/// mark it"). The phone holds no peg.
///
/// Read leniently: an entry that does not read is left out, never the rest.
struct AgroBenchmarks: Decodable, Equatable, Sendable {
    let sources: [String: AgroCalendar.Source]
    let yields: [Yield]
    let supportRates: [Rate]

    struct Yield: Decodable, Equatable, Sendable {
        let commodity: String
        let label: AgroCalendar.Text?
        let harvest: Int
        let kgPerHa: Int

        /// «Пшеница»: the server's label, else the commodity's own name.
        var title: String { label?.bg ?? CommodityName.canonical(commodity) ?? commodity }

        /// kg/дка: the hectare figure over 10.
        var kgPerDa: Double { Double(kgPerHa) / 10 }
    }

    struct Rate: Decodable, Equatable, Sendable, Identifiable {
        let scheme: String
        let label: AgroCalendar.Text?
        let campaign: Int
        /// The order's own currency: «BGN» until Campaign 2024, «EUR» from
        /// 2025 (agri-saas#3166). Absent on an older server, whose every rate
        /// was in leva.
        let currency: String?
        /// A caveat the server puts beside the rate — «Ставката за Кампания
        /// 2025 още не е обявена…».
        let note: AgroCalendar.Text?
        /// Euro cents per дка, converted by the server. A rate without it is
        /// not shown: the phone never shows the lev figure (EUR only).
        let perDaEurCents: Int?
        /// Above the 300th дка (30 ha), where the order sets a lower rate.
        let perDaOver30EurCents: Int?
        let commodities: [String]?
        let cite: AgroCalendar.Citation?
        var id: String { scheme }
        var title: String { label?.bg ?? scheme }
        /// Whether the euro figure was converted from leva. An order in euro
        /// is only divided per дка, and must not carry the converted marker.
        var isConverted: Bool { currency != "EUR" }
    }

    private enum CodingKeys: String, CodingKey { case sources, yields, supportRates }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = (try? c.decodeIfPresent([String: AgroCalendar.Source].self, forKey: .sources)) ?? [:]
        yields = (try? c.decodeIfPresent(AgroCalendar.Lenient<Yield>.self, forKey: .yields))?.values ?? []
        supportRates = (try? c.decodeIfPresent(AgroCalendar.Lenient<Rate>.self, forKey: .supportRates))?.values ?? []
    }

    /// The national yield for a commodity slug (`wheat`, `rapeseed`, …).
    func yield(for commodity: String?) -> Yield? {
        guard let commodity else { return nil }
        return yields.first { $0.commodity == commodity }
    }

    /// A calendar crop's national yield, by the commodity it joins.
    func yield(for crop: AgroCalendar.Crop) -> Yield? { yield(for: crop.commodityCanonical) }

    /// A calendar crop's coupled-support schemes.
    func rates(for crop: AgroCalendar.Crop) -> [Rate] { rates(for: crop.commodityCanonical) }

    /// The coupled-support schemes that name the commodity, euro figure known.
    func rates(for commodity: String?) -> [Rate] {
        guard let commodity else { return [] }
        return shownRates.filter { $0.commodities?.contains(commodity) == true }
    }

    /// Every rate the phone can show: the ones the server converted.
    var shownRates: [Rate] { supportRates.filter { $0.perDaEurCents != nil } }

    /// The year in the marker: the campaign the rates are for.
    var campaign: Int? { shownRates.map(\.campaign).max() }
}

enum AgroBenchmarksAPI {
    static let path = "/api/agro-benchmarks"

    static func decode(_ data: Data) async throws -> AgroBenchmarks {
        try await APIClient.shared.decode(data, as: AgroBenchmarks.self)
    }
}

/// The benchmarks, cache first: one small payload for every crop, loaded
/// once per screen.
@MainActor
@Observable
final class AgroBenchmarksStore {
    private(set) var state: LoadState<AgroBenchmarks> = .loading

    func load() async {
        guard state.value == nil else { return }
        await CachedResource.loadShowingCacheFirst(AgroBenchmarksAPI.path) { data in
            try await AgroBenchmarksAPI.decode(data)
        } publish: { [weak self] answer in
            self?.state = answer
        }
    }
}

/// The words for the benchmarks. The converted-figure marker is
/// `AgroWords.costsNote(year:)` — the vine card's, word for word.
enum BenchmarkWords {
    static let supportTitle = "Подпомагане"
    static let nationalTitle = "За страната"
    static let supportIntro = "Обвързана подкрепа за доходи: сума на декар допустима площ, по заповедта на министъра."

    /// «Среден добив за страната (2024)».
    static func yieldLabel(_ y: AgroBenchmarks.Yield) -> String {
        "Среден добив за страната (\(y.harvest))"
    }

    /// «573,1 кг/дка».
    static func yieldValue(_ y: AgroBenchmarks.Yield) -> String {
        "\(Num.text(y.kgPerDa)) кг/дка"
    }

    /// «Обвързана подкрепа (2024)».
    static func rateLabel(_ r: AgroBenchmarks.Rate) -> String {
        "Обвързана подкрепа (\(r.campaign))"
    }

    /// «13,02 EUR на дка».
    static func perDa(_ cents: Int) -> String { AgroWords.perDa(cents) }

    /// The rate's source line: «по МЗХ (2025)» for an order in euro, and the
    /// converted marker (`AgroWords.sourceNote`) for one converted from leva —
    /// per rate, since one list holds both (agri-saas#3166). The server's
    /// note follows.
    static func rateNote(_ r: AgroBenchmarks.Rate) -> String {
        let source = AgroWords.sourceNote(year: String(r.campaign), converted: r.isConverted)
        guard let note = r.note?.bg?.recorded else { return source }
        return "\(source). \(note)"
    }

    /// «Над 300 дка: 62,59 EUR на дка».
    static func over300(_ cents: Int) -> String { "Над 300 дка: \(perDa(cents))" }
}
