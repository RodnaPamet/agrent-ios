import SwiftUI
import UIKit

/// Задачи's «Изтрий» for several tasks (#625): the bar to send, the
/// question, the five seconds of «Отмени», and a refusal said.
/// `TaskBulkRemoval` holds the rules. Plain modifier functions, for the
/// reason `taskRemoval` gives.
extension View {
    func taskBulkRemoval(_ bulk: TaskBulkRemoval, reload: @escaping @MainActor () async -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if bulk.selecting {
                TaskBulkBar(bulk: bulk)
            } else if bulk.undoable {
                TaskBulkUndoBar(bulk: bulk)
            }
        }
        .alert(TaskBulkRemoval.confirmTitle(bulk.selected.count), isPresented: Bindable(bulk).asking) {
            Button(TaskBulkRemoval.actionTitle, role: .destructive) { TaskBulkRemovalControls.confirm(bulk) }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text(TaskBulkRemoval.confirmMessage)
        }
        .alert("Задачите не са изтрити", isPresented: Bindable(bulk).showsFailure, presenting: bulk.failure) { _ in
            Button("Затвори", role: .cancel) { bulk.dismissFailure() }
        } message: { failure in
            Text(failure)
        }
        .onChange(of: bulk.batches) {
            Task {
                await reload()
                bulk.listRead()
            }
        }
    }
}

@MainActor
enum TaskBulkRemovalControls {
    /// The confirmed question: the tasks go, the window starts (longer under
    /// VoiceOver or Switch Control), and it is said, with the way back.
    static func confirm(_ bulk: TaskBulkRemoval) {
        let count = bulk.selected.count
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        bulk.confirm(window: assisted ? TreatmentRemoval.assistedWindow : nil)
        var said = AttributedString(TaskBulkRemoval.announcement(count))
        said.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(said).post()
    }
}

/// While ticking: «Изтрий (N)», off until something is ticked.
private struct TaskBulkBar: View {
    let bulk: TaskBulkRemoval

    var body: some View {
        Button(role: .destructive) {
            bulk.ask()
        } label: {
            Label(TaskBulkRemoval.deleteButton(bulk.selected.count), systemImage: "trash")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(bulk.selected.isEmpty)
        .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .solidBar(hairline: .top)
    }
}

/// What went, with «Отмени», for the five seconds before it is sent.
private struct TaskBulkUndoBar: View {
    let bulk: TaskBulkRemoval

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TaskBulkRemoval.removedText(bulk.pendingCount))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { bulk.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}
