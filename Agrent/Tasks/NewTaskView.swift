import SwiftUI

/// «Нова задача» (agrent-ios#372, owner 2026-10-20): the web's
/// `NewTaskModal` fields that a phone needs. Title, description, a due day
/// and who does it. Opened from the + at the bottom right of «Задачи»
/// (`NewTaskButton`).
struct NewTaskView: View {
    /// The created task's id, when the answer said; the list reloads and
    /// opens it.
    let onCreated: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewTaskDraft()
    @State private var people = AssignableUsersStore()
    @State private var me: CurrentUser?
    @State private var saving = false
    @State private var failure: String?

    /// The route honours no key (see `NewTaskAPI`), so a lost answer may
    /// have made the task: said, rather than a retry promised safe.
    nonisolated static let unsureNote = "Ако връзката е прекъснала, задачата може вече да е създадена. "
        + "Проверете списъка, преди да опитате отново."

    var body: some View {
        NavigationStack {
            PageForm {
                TaskFormFields(draft: $draft,
                               choices: AssignableUsersStore.choices(people.state.value, me: me),
                               peopleFailed: people.state.isFailed)
                if let failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.unsureNote)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .inlineTitle("Нова задача")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().accessibilityLabel("Създаване")
                    } else {
                        Button("Създай") { Task { await save() } }
                            .disabled(draft.problem != nil)
                            .accessibilityHint(draft.problem ?? "")
                            .accessibilityInputLabels(A11y.Spoken.create)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            // No haptic, by `WriteFeedback`'s rule: this closes onto the
            // list and opens the new task, which is its own confirmation,
            // and a refusal is read out below.
            // Said, not only drawn: the refusal lands below the fold.
            .onChange(of: failure) { _, now in
                guard let now else { return }
                AccessibilityNotification.Announcement(now).post()
            }
            .task { me = await CurrentUserStore.shared.load() }
            .task { await people.load() }
        }
    }

    private func save() async {
        guard !saving, draft.problem == nil else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            let id = try await NewTaskAPI.create(draft.body)
            onCreated(id)
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// The + at the bottom right of «Задачи» (owner, 2026-10-20, #372).
///
/// Only for a person who may write in this farm, as «Нов запис» and «Нов
/// разход» are (`CurrentUser.mayWrite`, failing open while nobody has said).
/// An operator's job is completing work, not creating it.
///
/// Inside the tab's stack, so the task it creates opens on that stack.
struct NewTaskButton: View {
    /// The list's reload, before the new task opens over it.
    let reload: @MainActor () async -> Void

    @State private var composing = false
    @State private var people = CurrentUserStore.shared
    @Environment(\.pushRoute) private var pushRoute
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 56

    var body: some View {
        if people.user?.mayWrite ?? true {
            Button { composing = true } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    // Grows with the text, to a cap: a bigger target helps,
                    // a button that covers the list doesn't.
                    .frame(width: min(size, 76), height: min(size, 76))
            }
            .prominentButton()
            .buttonBorderShape(.circle)
            .accessibilityLabel("Нова задача")
            .accessibilityInputLabels(A11y.Spoken.newTask)
            // A glyph alone: the large content viewer says what it is to
            // someone who can't read the screen at its size.
            .accessibilityShowsLargeContentViewer {
                Label("Нова задача", systemImage: "plus")
            }
            .padding(20)
            .sheet(isPresented: $composing) {
                NewTaskView { id in
                    Task {
                        await reload()
                        if let id { pushRoute(.taskID(id)) }
                    }
                }
            }
        }
    }
}
