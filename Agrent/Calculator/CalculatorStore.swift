import Foundation
import Observation

@Observable
@MainActor
final class CalculatorStore {
    private(set) var state: LoadState<CalculatorPayload> = .loading

    /// «Всички» or one crop (owner, 2026-10-24), remembered PER FARM on this
    /// phone: the farm open when it was chosen is the farm it is about, and
    /// another farm's crops need not match. Not personal data, so sign-out
    /// leaves it, as Табло's arrangement (`DashboardPreferences`).
    private(set) var scope: CalculatorScope
    private let defaults: UserDefaults
    /// The farm `scope` was read for, so a switch of farm reads its own.
    private var scopeFarm: String?

    init(defaults: UserDefaults = .standard) {
        let farm = FarmPath.openSlug
        self.defaults = defaults
        scopeFarm = farm
        scope = CalculatorScope(stored: defaults.string(forKey: Self.key(farm)))
    }

    func choose(_ scope: CalculatorScope) {
        self.scope = scope
        defaults.set(scope.stored, forKey: Self.key(scopeFarm))
    }

    nonisolated static func key(_ farm: String?) -> String { "calculator.scope.\(farm ?? "")" }

    func load() async {
        if scopeFarm != FarmPath.openSlug {
            scopeFarm = FarmPath.openSlug
            scope = CalculatorScope(stored: defaults.string(forKey: Self.key(scopeFarm)))
        }
        // Same rule as the journal: only blank the screen when there is
        // nothing on it, so a refresh does not look like a loss.
        if state.value == nil { state = .loading }

        await CachedResource.loadShowingCacheFirst(CalculatorAPI.path) { data in
            try await CalculatorAPI.decode(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}

@Observable
@MainActor
final class CostsStore {
    /// The rows: the newest 500.
    private(set) var state: LoadState<CostPage> = .loading
    /// The totals over all of them (#503).
    private(set) var summary: LoadState<CostSummary> = .loading

    /// Read but not yet shown, waiting for its other half.
    @ObservationIgnored private var heldList: LoadState<CostPage>?
    @ObservationIgnored private var heldSummary: LoadState<CostSummary>?

    /// Both at once, each cache first, and shown IN PAIRS: the cached pair,
    /// then the fresh one. A fresh list under a cached summary would show
    /// a deleted expense gone from the rows and still in «Общо» until the
    /// second answer landed (`CostBreakdown`). Whatever is still held when
    /// both are done is shown then, so a summary that failed with a cache
    /// to fall back on never keeps the fresh rows off the screen, which is
    /// where a person checks that a save landed.
    func load() async {
        if state.value == nil { state = .loading }
        if summary.value == nil { summary = .loading }
        async let rows: Void = CachedResource.loadShowingCacheFirst(CostsAPI.listPath) { data in
            try await CostsAPI.decodeList(from: data)
        } publish: { [weak self] in self?.hold(list: $0) }
        async let totals: Void = CachedResource.loadShowingCacheFirst(CostsAPI.summaryPath) { data in
            try await CostsAPI.decodeSummary(from: data)
        } publish: { [weak self] in self?.hold(summary: $0) }
        _ = await (rows, totals)
        if let heldList { state = heldList }
        if let heldSummary { summary = heldSummary }
        heldList = nil
        heldSummary = nil
    }

    private func hold(list: LoadState<CostPage>? = nil, summary: LoadState<CostSummary>? = nil) {
        if let list { heldList = list }
        if let summary { heldSummary = summary }
        guard let heldList, let heldSummary else { return }
        state = heldList
        self.summary = heldSummary
        self.heldList = nil
        self.heldSummary = nil
    }
}
