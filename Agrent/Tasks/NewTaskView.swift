import SwiftUI

/// «Нова задача» (agrent-ios#372, owner 2026-10-20): the web's
/// `NewTaskModal` fields that a phone needs. Title, description, a due day
/// and who does it. Opened from the + at the bottom right of «Задачи»
/// (`NewTaskButton`).
///
/// Two steps since #388 (owner, 2026-10-21): «Напред» opens «Парцели», where
/// the task's parcels are chosen by block, optionally, and «Създай» is
/// there. Like «Ново мероприятие».
struct NewTaskView: View {
    /// The created task's id, when the answer said; the list reloads and
    /// opens it.
    let onCreated: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewTaskDraft()
    @State private var people = AssignableUsersStore()
    @State private var me: CurrentUser?
    @State private var path: [Step] = []
    @State private var blocks = TaskBlocksStore()
    @State private var blockID: String?
    @State private var chosen: Set<String> = []
    @State private var saving = false
    @State private var failure: String?
    /// The task, once created: `.some(id)`, the id nil if the answer
    /// couldn't be read. Never created twice (`NewTaskSave`).
    @State private var created: String??
    /// The parcels linked to it so far.
    @State private var linked: Set<String> = []

    enum Step: Hashable { case parcels }

    /// The route honours no key (see `NewTaskAPI`), so a lost answer may
    /// have made the task: said, rather than a retry promised safe.
    nonisolated static let unsureNote = "Ако връзката е прекъснала, задачата може вече да е създадена. "
        + "Проверете списъка, преди да опитате отново."

    var body: some View {
        NavigationStack(path: $path) {
            PageForm {
                TaskFormFields(draft: $draft,
                               choices: AssignableUsersStore.choices(people.state.value, me: me),
                               peopleFailed: people.state.isFailed)
            }
            .inlineTitle("Нова задача")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Напред") { path.append(.parcels) }
                        .disabled(draft.problem != nil)
                        .accessibilityHint(draft.problem ?? "")
                        .accessibilityInputLabels(A11y.Spoken.next)
                }
            }
            .navigationDestination(for: Step.self) { _ in
                NewTaskParcelsView(
                    store: blocks, blockID: $blockID, chosen: $chosen,
                    saving: saving, failure: failure,
                    primaryTitle: created == nil ? "Създай" : "Опитай пак",
                    onPrimary: { Task { await save() } },
                    onDone: created == nil ? nil : { finish(created ?? nil) })
                // Once the task exists there is no going back to edit it:
                // what step one says is already on the server.
                .navigationBarBackButtonHidden(saving || created != nil)
                .toolbar {
                    if created == nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Отказ") { dismiss() }
                                .disabled(saving)
                                .accessibilityInputLabels(A11y.Spoken.cancel)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(saving || created != nil)
            // No haptic, by `WriteFeedback`'s rule: this closes onto the
            // list and opens the new task, which is its own confirmation,
            // and a refusal is read out on the parcels step.
            .task { me = await CurrentUserStore.shared.load() }
            .task { await people.load() }
            // The blocks are read as step one opens, so they're in hand by
            // «Напред». A farm with one block has it chosen.
            .task {
                await blocks.load()
                if blockID == nil, let only = blocks.blocks.value, only.count == 1 {
                    blockID = only[0].id
                }
            }
        }
    }

    /// The task, if it doesn't exist yet, then the parcels not linked yet.
    private func save() async {
        guard !saving, draft.problem == nil else { return }
        saving = true
        failure = nil
        defer { saving = false }
        let id: String?
        if let made = created {
            id = made
        } else {
            do {
                id = try await NewTaskAPI.create(draft.body)
                created = .some(id)
            } catch {
                failure = UserMessage.text(for: error) + " " + Self.unsureNote
                return
            }
        }
        let pending = NewTaskSave.pending(chosen: chosen, linked: linked)
        guard !pending.isEmpty else { return finish(id) }
        guard let id else {
            // A 201 whose body couldn't be read: the task exists, but which
            // one isn't known, so its parcels can't be attached from here.
            failure = "Задачата е създадена, но парцелите не можаха да се добавят. Добавете ги от сайта."
            return
        }
        linked.formUnion(await NewTaskSave.link(pending, to: id) { parcel, task in
            try await TaskLinksAPI.linkParcel(parcel, to: task)
        })
        let missing = NewTaskSave.pending(chosen: chosen, linked: linked).count
        if missing == 0 { finish(id) } else { failure = NewTaskSave.partial(missing) }
    }

    private func finish(_ id: String?) {
        onCreated(id)
        dismiss()
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
