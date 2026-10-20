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
    /// The server matches a crop against what each farm typed, ignoring
    /// case but nothing else («пшеница» finds «Пшеница», not «Пшеница
    /// (мека)»; agri-saas #2069). A fixed list of crop names would offer
    /// choices that find nothing. A value taken from an answer finds at
    /// least the farm it came from. It only grows, so a filter that narrows
    /// the list doesn't narrow the choices with it.
    ///
    /// One choice per crop, not per spelling: two that differ only in case
    /// find the same farms, so the menu keeps the first one seen.
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
        let merged = Self.merged(knownCrops, with: hits.flatMap(\.crops))
        guard merged.count != knownCrops.count else { return }
        knownCrops = merged
    }

    /// `known` plus each crop in `found` whose case-folded spelling it
    /// doesn't have yet, in Bulgarian order. Folded as the server's
    /// `lower()` folds, so the menu merges exactly the spellings the
    /// filter does.
    nonisolated static func merged(_ known: [String], with found: [String]) -> [String] {
        let bulgarian = Locale(identifier: "bg_BG")
        var seen = Set(known.map { $0.lowercased(with: bulgarian) })
        let new = found.filter { seen.insert($0.lowercased(with: bulgarian)).inserted }
        return new.isEmpty ? known : sorted(known + new)
    }

    /// Alphabetical as a Bulgarian reads it, whatever the phone's language.
    nonisolated static func sorted(_ crops: [String]) -> [String] {
        let bulgarian = Locale(identifier: "bg_BG")
        return crops.sorted {
            $0.compare($1, options: [.caseInsensitive], range: nil, locale: bulgarian) == .orderedAscending
        }
    }
}
