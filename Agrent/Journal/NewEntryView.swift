import SwiftUI

struct NewEntryView: View {
    let store: JournalStore

    @Environment(\.dismiss) private var dismiss
    @State private var type: LogEntryType = .activity
    @State private var title = ""
    @State private var notes = ""
    @State private var occurredAt = Date()
    @State private var saving = false
    @State private var error: String?

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    // `MenuPicker`, not a bare `Picker`: the system's menu
                    // picker drew «Дейност» as «Де…ст» here, at the default
                    // text size (#160).
                    MenuPicker("Тип", english: "Type", selection: $type, value: type.label) {
                        // `selectable`, never `allCases` — the latter now carries
                        // `.unknown`, whose raw value the server would reject.
                        ForEach(LogEntryType.selectable) { Text($0.label).tag($0) }
                    }
                    DatePicker("Дата", selection: $occurredAt, displayedComponents: .date)
                }
                Section(titled: "Заглавие") {
                    // No font-size dance here. UIKit's text input does not
                    // focus-zoom, which is the entire class of bug that took
                    // five fixes on the web.
                    TextField("Заглавие", text: $title,
                              prompt: .fieldPrompt("напр. Третиране на южния блок"), axis: .vertical)
                }
                Section(titled: "Бележки") {
                    TextEditor(text: $notes).frame(minHeight: 140)
                }
                if let error {
                    Section {
                        // `Palette.error`, not `.red` — 5.42:1 against
                        // 3.55:1, and the app has one colour for a failure.
                        Text(error).foregroundStyle(Palette.error)
                    }
                }
            }
            .inlineTitle("Нов запис")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Създай") { Task { await save() } }
                        .accessibilityInputLabels(A11y.Spoken.create)
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        saving = true
        error = nil
        do {
            try await store.create(CreateLogEntry(
                type: type,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                // `notes` is a rich-text HTML column on both ends; the app
                // was POSTing plain text, so a two-paragraph note read as
                // one run-on paragraph on the web. See RichText.
                notes: RichText.html(fromPlainText: notes),
                occurredAt: occurredAt
            ))
            dismiss()
        } catch {
            // Stay open on failure. Closing a form after a refused write is
            // exactly the defect filed against the web app as #921 — it reads
            // as success and the operator's work is gone.
            self.error = UserMessage.text(for: error)
        }
        saving = false
    }
}
