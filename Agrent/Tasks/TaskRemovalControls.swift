import SwiftUI
import UIKit

/// A list of tasks' «Изтрий» (#454, owner 2026-10-26): the question, the
/// five seconds of «Отмени» under the list, and a refusal said. Shared by
/// Задачи and a parcel's «Текущи» / «Архив» (owner 2026-10-30), so a task
/// is deleted the same way from either list. `TaskRemoval` holds the rules;
/// this is where they meet the screen.
///
/// ── Plain modifiers, NOT a `ViewModifier` with state ──
///
/// The first version was a `ViewModifier` struct holding the refusal's
/// `@State`. Wrapped around Задачи's list it crashed UIKit the moment the
/// swipe's «Изтрий» was pressed («Invalid number of items in section», in
/// the list's batch update), while the same modifiers written inline, as
/// they had been since #454, did not. Measured by A11yShots
/// `testTaskSwipeDeleteAndUndo`: inline passes, the struct crashes every
/// time. So these are the inline modifiers, applied by a function, and the
/// refusal's switch lives on `TaskRemoval` (`showsFailure`).
extension View {
    /// The list's side of «Изтрий». `asking` and `confirming` are the
    /// caller's state for the row being asked about; `reload` reads the list
    /// again once the server took a delete.
    func taskRemoval(
        _ removal: TaskRemoval,
        asking: Binding<WorkItemSummary?>,
        confirming: Binding<Bool>,
        reload: @escaping @MainActor () async -> Void
    ) -> some View {
        // Under the list: what went, and «Отмени» for its five seconds.
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let undoable = removal.undoable { TaskUndoBar(removal: removal, undoable: undoable) }
        }
        .alert(TaskRemoval.confirmTitle, isPresented: confirming, presenting: asking.wrappedValue) { item in
            Button(TreatmentRemoval.actionTitle, role: .destructive) { TaskRemovalControls.remove(item, from: removal) }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: { item in
            Text(item.title)
        }
        .alert("Задачата не е изтрита", isPresented: Bindable(removal).showsFailure, presenting: removal.failure) { _ in
            Button("Затвори", role: .cancel) { removal.dismissFailure() }
        } message: { failure in
            Text(failure)
        }
        // The server took a delete: the list as it now stands, and any sent
        // row it no longer lists stops being hidden.
        .onChange(of: removal.deletions) {
            Task {
                await reload()
                removal.listRead()
            }
        }
    }

    /// A row's «Изтрий», only where the server says it would succeed
    /// (`TaskRemoval.offered`). Not a full swipe: «Изтрий», then the
    /// question, then five seconds of «Отмени» (owner, 2026-10-26).
    func taskRemovalSwipe(_ item: WorkItemSummary, me: CurrentUser?, ask: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if TaskRemoval.offered(item, to: me) {
                Button(role: .destructive, action: ask) {
                    Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            }
        }
    }
}

@MainActor
enum TaskRemovalControls {
    /// The confirmed «Изтрий»: the row goes, the five seconds start (longer
    /// under VoiceOver or Switch Control), and it is said, with the way back.
    static func remove(_ item: WorkItemSummary, from removal: TaskRemoval) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        removal.remove(item, window: assisted ? TreatmentRemoval.assistedWindow : nil)
        if let going = removal.undoable {
            var said = AttributedString(TaskRemoval.announcement(going))
            said.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(said).post()
        }
    }
}

/// What went, with «Отмени», for the five seconds before it is sent:
/// Дневник's bar, for a task.
private struct TaskUndoBar: View {
    let removal: TaskRemoval
    let undoable: TaskRemoval.Undoable

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TaskRemoval.removedText(undoable))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { removal.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}

extension TaskRemoval {
    /// The rows a list shows: the server's, less what was swiped away.
    func visible(_ items: [WorkItemSummary]) -> [WorkItemSummary] {
        let gone = hidden
        return gone.isEmpty ? items : items.filter { !gone.contains($0.id) }
    }
}
