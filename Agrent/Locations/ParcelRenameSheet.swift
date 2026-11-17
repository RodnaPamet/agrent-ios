import SwiftUI

/// «Преименувай»: the farmer's own name for a parcel (owner, 2026-11-17,
/// #667) — "so that he can easily relate to their names in the assistant".
///
/// A NICKNAME. The footer says so in the farmer's words, because the one
/// thing a rename must not make anybody fear is that the papers changed: the
/// ДНЕВНИК keeps the field number, and an empty name brings the number back.
struct ParcelRenameSheet: View {
    /// The field number, which the ДНЕВНИК keeps. Also the prompt, so an
    /// empty field shows what the parcel will be called.
    let number: String
    let current: String?
    let save: (String?) async throws -> Void

    @State private var text: String
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(number: String, current: String?, save: @escaping (String?) async throws -> Void) {
        self.number = number
        self.current = current
        self.save = save
        _text = State(initialValue: current ?? "")
    }

    /// What would be sent: trimmed, nil when blank — and nil when it only
    /// repeats the number, which is the same as having no nickname.
    private var value: String? { ParcelNickname.shown(text, number: number) }

    private var problem: String? {
        text.count > ParcelNickname.maxLength
            ? "Името е твърде дълго. До \(ParcelNickname.maxLength) знака." : nil
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField("Име", text: $text, prompt: .fieldPrompt(number))
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit { Task { await commit() } }
                } header: {
                    SectionHeader("Име")
                } footer: {
                    SectionFooter {
                        Text("Така ще го виждате в приложението и така ще го разбира Агрент. "
                             + "В дневника остава номерът \(number). Празно поле връща номера.")
                    }
                }
                if let message = problem ?? failure {
                    Section {
                        Text(message).foregroundStyle(Palette.error)
                    }
                }
            }
            .inlineTitle("Преименувай")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await commit() } }
                        .disabled(problem != nil || saving)
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { focused = true }
        }
    }

    private func commit() async {
        guard problem == nil, !saving else { return }
        // Nothing changed: nothing sent.
        guard value != ParcelNickname.shown(current, number: number) else { return dismiss() }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            try await save(value)
            dismiss()
        } catch {
            // The old name stays: nothing was applied before the server
            // answered.
            failure = UserMessage.text(for: error)
        }
    }
}
