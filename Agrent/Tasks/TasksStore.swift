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

@Observable
@MainActor
final class TaskDetailStore {
    private(set) var state: LoadState<WorkItem> = .loading
    private let id: String

    init(id: String) { self.id = id }

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(WorkItemAPI.detailPath(id)) { data in
            try await WorkItemAPI.decodeDetail(from: data)
        }
    }
}
