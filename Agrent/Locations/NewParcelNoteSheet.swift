import SwiftUI

/// «Нов коментар» on a parcel (owner, 2026-11-06: "Comment living only in
/// the history page of a parcel"): free text about the field, on no task,
/// from the «+» of its «Коментари». It is listed there with the task
/// comments, and nowhere else.
///
/// Sent with an `Idempotency-Key` minted when the sheet opens, so «Запази»
/// tapped again after a lost answer returns the same note rather than a
/// second one. No edit and no delete: the server has neither, and whether a
/// note may be removed is with the owner.
struct NewParcelNoteSheet: View {
    let parcelID: String
    /// After the 201: the list reads itself again.
    let onSaved: () -> Void

    @State private var text = ""
    @State private var key = UUID().uuidString
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField("Коментар", text: $text, prompt: .fieldPrompt("Какво има да се знае за този парцел"),
                              axis: .vertical)
                        .lineLimit(4...12)
                        .onChange(of: text) { _, now in
                            if now.count > ParcelCommentsAPI.maxNote {
                                text = String(now.prefix(ParcelCommentsAPI.maxNote))
                            }
                        }
                } header: {
                    SectionHeader("Коментар")
                } footer: {
                    SectionFooter {
                        if let failure {
                            Text(failure).foregroundStyle(Palette.error)
                        } else {
                            Text("За самия парцел, без задача. Вижда се само в историята му.")
                        }
                    }
                }
            }
            .inlineTitle("Нов коментар")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(trimmed.isEmpty || saving)
                        .accessibilityHint(trimmed.isEmpty ? "Напишете коментара." : "")
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving || !trimmed.isEmpty)
        }
    }

    private func save() async {
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            try await ParcelCommentsAPI.createNote(parcelID: parcelID, body: trimmed, idempotencyKey: key)
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
