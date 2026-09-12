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
            Form {
                Section {
                    Picker("Тип", selection: $type) {
                        ForEach(LogEntryType.allCases) { Text($0.label).tag($0) }
                    }
                    DatePicker("Дата", selection: $occurredAt, displayedComponents: .date)
                }
                Section("Заглавие") {
                    // No font-size dance here. UIKit's text input does not
                    // focus-zoom, which is the entire class of bug that took
                    // five fixes on the web.
                    TextField("напр. Третиране на южния блок", text: $title, axis: .vertical)
                }
                Section("Бележки") {
                    TextEditor(text: $notes).frame(minHeight: 140)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Нов запис")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Създай") { Task { await save() } }
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
                notes: notes.isEmpty ? nil : notes,
                occurredAt: occurredAt
            ))
            dismiss()
        } catch {
            // Stay open on failure. Closing a form after a refused write is
            // exactly the defect filed against the web app as #921 — it reads
            // as success and the operator's work is gone.
            self.error = error.localizedDescription
        }
        saving = false
    }
}
