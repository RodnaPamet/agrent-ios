import SwiftUI

/// «Редактирай» on a task (agrent-ios#382, owner 2026-10-21): the «Нова
/// задача» form, opened on the task as it stands. Offered to the task's
/// creator and the farm's administrators (`TaskEdit.mayEdit`).
struct EditTaskView: View {
    let item: WorkItem
    /// After a save, so the task re-reads under the sheet.
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    /// The task as the form last knew it on the server: as opened, then as
    /// each part landed. Changes are worked out against this.
    @State private var original: NewTaskDraft
    @State private var draft: NewTaskDraft
    @State private var people = AssignableUsersStore()
    @State private var me: CurrentUser?
    @State private var saving = false
    @State private var failure: String?

    init(item: WorkItem, onSaved: @escaping @MainActor () async -> Void) {
        self.item = item
        self.onSaved = onSaved
        let draft = TaskEdit.draft(from: item)
        _original = State(initialValue: draft)
        _draft = State(initialValue: draft)
    }

    private var changes: TaskEdit.Changes { TaskEdit.changes(from: original, to: draft) }

    /// What stands in the way of «Запази», or nil.
    private var problem: String? {
        draft.problem ?? (changes.isEmpty ? "Няма промени." : nil)
    }

    var body: some View {
        NavigationStack {
            PageForm {
                TaskFormFields(
                    draft: $draft,
                    choices: TaskEdit.choices(AssignableUsersStore.choices(people.state.value, me: me),
                                              keeping: item.assignee),
                    peopleFailed: people.state.isFailed
                )
                if let failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .inlineTitle("Редактирай задачата")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().accessibilityLabel("Запазване")
                    } else {
                        Button("Запази") { Task { await save() } }
                            .disabled(problem != nil)
                            .accessibilityHint(problem ?? "")
                            .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            // No haptic, by `WriteFeedback`'s rule, as «Нова задача»: this
            // closes onto the task, which shows what changed, and a refusal
            // is read out below.
            .onChange(of: failure) { _, now in
                guard let now else { return }
                AccessibilityNotification.Announcement(now).post()
            }
            .task { me = await CurrentUserStore.shared.load() }
            .task { await people.load() }
        }
    }

    /// The fields first, then the assignee, each only if it changed. What
    /// landed becomes the baseline, so after a refused assignee a second
    /// «Запази» sends only the assignee.
    private func save() async {
        guard !saving, problem == nil else { return }
        saving = true
        failure = nil
        defer { saving = false }
        // As it was when «Запази» was tapped: anything typed while this is
        // out was not sent, so it must not become the baseline.
        let sent = draft
        let changes = TaskEdit.changes(from: original, to: sent)
        do {
            if !changes.patch.isEmpty {
                try await TaskEditAPI.update(item.id, changes.patch)
                original.title = sent.title
                original.details = sent.details
                original.hasDue = sent.hasDue
                original.due = sent.due
            }
            if let assignee = changes.assignee {
                try await TaskEditAPI.assign(item.id, to: assignee)
                original.assigneeID = assignee
            }
            await onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
