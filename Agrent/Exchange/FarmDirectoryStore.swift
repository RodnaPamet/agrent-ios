import Foundation
import Observation

/// «Ферми»: the published farms, searched by name and filtered by oblast and
/// crop (#323). Network only: see `FarmDirectoryAPI`.
@Observable
@MainActor
final class FarmDirectoryStore {
    private(set) var state: LoadState<[FarmDirectoryHit]> = .loading

    var query = FarmDirectoryQuery()

    /// Every crop an answer has carried, for the crop filter.
    ///
    /// ── Why from the answers, not a list of crops ──
    ///
    /// The server matches a crop EXACTLY, case included, against what each
    /// farm typed («Пшеница» doesn't find «пшеница»). A fixed list of crop
    /// names would offer choices that find nothing. A value taken from an
    /// answer finds at least the farm it came from. It only grows, so a
    /// filter that narrows the list doesn't narrow the choices with it.
    /// agri-saas #1909 asks the server to compare crops case-insensitively;
    /// once it does, a choice per spelling is still right, only redundant.
    private(set) var knownCrops: [String] = []

    /// Which load is the latest. Counted, not compared by query: the search
    /// text is bound to the field, so it changes as someone types, before
    /// they search again.
    @ObservationIgnored private var asked = 0

    func load() async {
        if state.value == nil { state = .loading }
        asked += 1
        let mine = asked
        do {
            let hits = try await FarmDirectoryAPI.search(query)
            // A newer search went out while this one was in flight. Its
            // answer is the one to show, and it publishes itself.
            guard mine == asked else { return }
            state = .loaded(hits, .fresh)
            remember(hits)
        } catch {
            guard mine == asked else { return }
            state = .failed(UserMessage.text(for: error))
        }
    }

    /// The screen reloads on the change, as for any other filter choice.
    func clearFilters() {
        query.oblast = nil
        query.crop = nil
    }

    private func remember(_ hits: [FarmDirectoryHit]) {
        let new = Set(hits.flatMap(\.crops)).subtracting(knownCrops)
        guard !new.isEmpty else { return }
        knownCrops = Self.sorted(knownCrops + new)
    }

    /// Alphabetical as a Bulgarian reads it, whatever the phone's language.
    nonisolated static func sorted(_ crops: [String]) -> [String] {
        let bulgarian = Locale(identifier: "bg_BG")
        return crops.sorted {
            $0.compare($1, options: [.caseInsensitive], range: nil, locale: bulgarian) == .orderedAscending
        }
    }
}
