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
    private(set) var state: LoadState<CostPage> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(CostsAPI.listPath) { data in
            try await CostsAPI.decodeList(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}
