import Foundation
import Observation

@Observable
@MainActor
final class CalculatorStore {
    private(set) var state: LoadState<CalculatorPayload> = .loading

    func load() async {
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
