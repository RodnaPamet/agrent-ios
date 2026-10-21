import SwiftUI

/// The fields «Нова задача» (#372) and «Редактирай» (#382) share: title,
/// description, a due day and who does it. One form, so the two can't drift.
struct TaskFormFields: View {
    @Binding var draft: NewTaskDraft
    let choices: [AssignableUsersStore.Choice]
    /// The farm's people didn't load: the footer says what that leaves.
    let peopleFailed: Bool

    private static let titleExample = "напр. Почистване на канала"

    private var assigneeLabel: String {
        guard let id = draft.assigneeID else { return "Без изпълнител" }
        return choices.first { $0.id == id }?.label ?? "Без изпълнител"
    }

    var body: some View {
        Section(titled: "Заглавие") {
            TextField("Заглавие", text: $draft.title,
                      prompt: .fieldPrompt(Self.titleExample), axis: .vertical)
                .promptRoom(Self.titleExample)
        }
        Section(titled: "Описание") {
            TextField("Описание", text: $draft.details,
                      prompt: .fieldPrompt("По избор"), axis: .vertical)
                .lineLimit(3...10)
        }
        Section {
            Toggle("Краен срок", isOn: $draft.hasDue)
            if draft.hasDue {
                DatePicker("Дата", selection: $draft.due, displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
            }
        }
        Section {
            MenuPicker("Изпълнител", english: "Assignee", selection: $draft.assigneeID,
                       value: assigneeLabel) {
                Text("Без изпълнител").tag(String?.none)
                ForEach(choices) { Text($0.label).tag(String?.some($0.id)) }
            }
        } footer: {
            SectionFooter {
                if peopleFailed {
                    Text("Списъкът с хора не се зареди. Задачата може да е без изпълнител или Ваша.")
                } else {
                    Text("Изпълнителят я вижда в «Задачи» и получава известие.")
                }
            }
        }
    }
}
