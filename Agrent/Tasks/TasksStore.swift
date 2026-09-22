import Foundation
import Observation

@Observable
@MainActor
final class TasksStore {
    private(set) var state: LoadState<WorkItemPage> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(WorkItemAPI.listPath) { data in
            try await WorkItemAPI.decodeList(from: data)
        }
    }
}
