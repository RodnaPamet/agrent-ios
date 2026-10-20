import SwiftUI

/// A task reached by id: a tapped notification (#368).
///
/// `TaskDetailView` starts from a row, and a notification carries only the
/// task's id. So the task is read first and its screen is shown from it.
/// The read is cache-first, so the screen's own read of the same task
/// answers at once.
struct TaskLinkView: View {
    let id: String

    @State private var store: TaskDetailStore

    init(id: String) {
        self.id = id
        _store = State(initialValue: TaskDetailStore(id: id))
    }

    var body: some View {
        Group {
            switch store.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Зареждане на задачата")
            case .failed(let message):
                ErrorState(message: message) { await store.load() }
            case .loaded(let item, _):
                TaskDetailView(summary: WorkItemSummary(item: item))
            }
        }
        .task { if store.state.value == nil { await store.load() } }
    }
}
