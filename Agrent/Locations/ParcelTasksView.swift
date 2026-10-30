import SwiftUI

/// A parcel's tasks, «Текущи» and «Архив» (#462, owner 2026-10-29): what its
/// «Задачи» card opens, from the parcel's screen in Блокове. A row opens the
/// task, as on Задачи.
///
/// And a row is deleted as on Задачи (owner, 2026-10-30): swipe «Изтрий»,
/// the question, five seconds of «Отмени», through the same
/// `taskRemoval`, offered only where the server says it would succeed.
/// The parcel's card reads the same store, so it follows.
struct ParcelTasksView: View {
    let parcelName: String
    let store: ParcelTasksStore

    @State private var tab: ParcelTasks.Tab = .current
    /// Who is signed in: whether to offer «Изтрий».
    @State private var people = CurrentUserStore.shared
    /// Rows swiped away, inside their five seconds or just sent.
    @State private var removal = TaskRemoval()
    @State private var confirmingRemoval: WorkItemSummary?
    @State private var confirming = false
    /// Set once the list has been on screen: a later appearance is a return
    /// from a task, which may have been closed there.
    @State private var shownBefore = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        content
            .inlineTitle(ParcelTasksCard.title)
            .taskRemoval(removal, asking: $confirmingRemoval, confirming: $confirming) {
                await store.load()
            }
            .task { _ = await people.load() }
            // Back from a task: read again, so a task closed there is under
            // the tab its status now names. Cache-first, so the rows stay
            // while it reads.
            .onAppear {
                if shownBefore { Task { await store.load() } }
                shownBefore = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let tasks, _):
            List {
                Group {
                    // Whose field: one push from the parcel, and nothing
                    // else on screen says.
                    Text(parcelName)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .listRowSeparator(.hidden)
                    tabPicker
                        .listRowSeparator(.hidden)
                    if tasks.truncated {
                        RefusalNote(
                            text: "Списъкът е съкратен от сървъра. Не всички задачи се показват.",
                            icon: "exclamationmark.triangle"
                        )
                    }
                    // A row swiped away isn't listed or counted.
                    rows(removal.visible(tasks.rows(tab)))
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }

    /// Two words side by side; a menu at the accessibility sizes, where a
    /// segment would cut a word short.
    @ViewBuilder
    private var tabPicker: some View {
        let picker = Picker("Задачи", selection: $tab) {
            ForEach(ParcelTasks.Tab.allCases, id: \.self) { each in
                Text(each.label).tag(each)
            }
        }
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func rows(_ items: [WorkItemSummary]) -> some View {
        if items.isEmpty {
            Text(tab.emptyText)
                .font(.body)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
        } else {
            Section(titled: Plural.bg(items.count, "задача", "задачи")) {
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.task(item)) {
                        TaskRow(item: item)
                    }
                    .pageRow()
                    .taskRemovalSwipe(item, me: people.user) {
                        confirmingRemoval = item
                        confirming = true
                    }
                }
            }
        }
    }
}
