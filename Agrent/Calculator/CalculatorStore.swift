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

        state = await CachedResource.load(CalculatorAPI.path) { data in
            try await CalculatorAPI.decode(from: data)
        }
    }
}

@Observable
@MainActor
final class CostsStore {
    private(set) var state: LoadState<CostPage> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(CostsAPI.listPath) { data in
            try await CostsAPI.decodeList(from: data)
        }
    }
}
