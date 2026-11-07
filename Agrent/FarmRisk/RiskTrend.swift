import Foundation
import Observation

/// A parcel's satellite readings over a period (owner, 2026-11-07: "store
/// past data so the app and the assistant provide info based on a time
/// period, like the past 14 days"; agri-saas #2837 stage 1).
///
/// `GET …/agro/parcels/{id}/analysis/history?days=` answers every Sentinel-2
/// pass in the window, oldest first, one per date. Each pass is the «Риск»
/// card's own reading: the same `RiskLevel`s, worked out by the same
/// functions, so a point and the card above it cannot disagree.
struct ParcelRiskHistory: Decodable, Equatable, Sendable {
    /// The window USED: the server clamps 7–120 and says what it did, so
    /// this is read, never assumed from what was asked.
    let days: Int
    /// False: satellite analysis is not set up on this deployment, so no
    /// pass was ever looked at, which is not the same as none being usable.
    let configured: Bool
    let truncated: Bool
    let passes: [Pass]

    struct Pass: Decodable, Equatable, Sendable, Identifiable {
        /// The acquisition day, `YYYY-MM-DD`.
        let date: String
        /// Null: this pass was under cloud over the parcel. A GAP, never 0,
        /// which would draw a fall to bare soil that never happened.
        let ndvi: Double?
        let ndmi: Double?
        let vegetation: RiskLevel
        let moisture: RiskLevel
        /// `stored` (final) or `earthengine` (computed for this request),
        /// once the stored record lands (stage 1b); absent before it.
        let source: String?

        var id: String { date }
        var day: Date? { BgDate.parseISODay(date) }
    }
}

enum RiskTrendAPI {
    /// The periods offered: 14 days by default, as the server's own default.
    static let periods = [14, 30, 60]

    static func path(_ parcelID: String, days: Int) -> String {
        "\(FarmRiskAPI.analysisPath(parcelID))/history?days=\(days)"
    }

    static func decode(_ data: Data) async throws -> ParcelRiskHistory {
        try await APIClient.shared.decode(data, as: ParcelRiskHistory.self)
    }
}

/// One parcel's trend for the period chosen, cache first like its reading.
/// `days` is the picker's own selection; a load answers for the period it
/// was asked for, and an answer for a period no longer chosen is dropped
/// (14 → 30 → 60 tapped quickly must not end on 30's chart under «60»).
@MainActor
@Observable
final class RiskTrendStore {
    private(set) var state: LoadState<ParcelRiskHistory> = .loading
    var days = RiskTrendAPI.periods[0]
    /// The period `state` is for, so a reappearing row does not ask again.
    private(set) var loadedDays: Int?
    private let parcelID: String

    init(parcelID: String) { self.parcelID = parcelID }

    func load() async {
        let asked = days
        // Answered already. A load cut off (the row scrolled away) leaves
        // `.loading`, and is asked again rather than spinning for good.
        guard loadedDays != asked || state.value == nil else { return }
        state = .loading
        loadedDays = asked
        await CachedResource.loadShowingCacheFirst(RiskTrendAPI.path(parcelID, days: asked)) { data in
            try await RiskTrendAPI.decode(data)
        } publish: { [weak self] answer in
            guard let self, self.days == asked else { return }
            self.state = answer
        }
        // A failure lets the same period be asked again on the next appear.
        if days == asked, state.isFailed { loadedDays = nil }
    }
}

/// The period's change in words, for the screen and for the assistant's
/// question: «За 14 дни зеленината спадна от 0,72 до 0,51 (−29 %)». Pure,
/// so tests pin it.
enum RiskTrendWords {
    /// First and last pass with a value, over the period the server used.
    static func change(_ history: ParcelRiskHistory) -> String? {
        var sentences: [String] = []
        if let ndvi = Self.ends(history.passes.compactMap(\.ndvi)) {
            sentences.append(Self.sentence("зеленината", ndvi))
        }
        if let ndmi = Self.ends(history.passes.compactMap(\.ndmi)) {
            sentences.append(Self.sentence("влагата", ndmi))
        }
        guard !sentences.isEmpty else { return nil }
        return "За \(history.days) дни " + sentences.joined(separator: ", а ") + "."
    }

    /// Why there is no line, in words: not set up, or no clear pass.
    static func empty(_ history: ParcelRiskHistory) -> String? {
        if !history.configured { return "Сателитният анализ не е настроен, затова няма история." }
        if history.passes.allSatisfy({ $0.ndvi == nil && $0.ndmi == nil }) {
            return "Няма ясна сателитна снимка за последните \(history.days) дни (облачно)."
        }
        return nil
    }

    private static func ends(_ values: [Double]) -> (first: Double, last: Double)? {
        guard values.count >= 2, let first = values.first, let last = values.last else { return nil }
        return (first, last)
    }

    private static func sentence(_ what: String, _ ends: (first: Double, last: Double)) -> String {
        let from = Self.index(ends.first), to = Self.index(ends.last)
        let delta = ends.last - ends.first
        // Within a hundredth: no movement worth a verb.
        guard abs(delta) >= 0.01 else { return "\(what) остана около \(to)" }
        let verb = delta < 0 ? "спадна" : "се повиши"
        // A percentage only from a base far enough from 0 to mean something;
        // NDMI hovers round 0 and «+400 %» there says nothing. A no-break
        // space before «%», or «(−9» and «%)» break across lines (measured).
        let percent = abs(ends.first) >= 0.1
            ? " (\(delta < 0 ? "−" : "+")\(WeatherWords.number(abs(delta / ends.first) * 100, places: 0))\u{00A0}%)" : ""
        return "\(what) \(verb) от \(from) до \(to)\(percent)"
    }

    /// «0,50»: an index always to two places, so the two ends of a change
    /// read alike («от 0,50 до 0,62», not «от 0,5 до 0,62»).
    static func index(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(BgDate.locale))
    }
}
