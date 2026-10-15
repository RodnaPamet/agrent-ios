import SwiftUI

/// Choosing the web address the farm's page opens at (`/f/{handle}`,
/// agri-saas #1865).
///
/// ── The server decides the spelling ──
///
/// It transliterates and lower-cases what was typed, so «Победа» is stored
/// as `pobeda`, and the page says the address it got back
/// (`PublicProfileView.claimedNote`), never the typed one. Nothing here
/// imitates that rule, so the two can't drift: the phone would only be
/// guessing.
///
/// ── Taken, with what to try instead ──
///
/// The namespace is every farm's, so this is the one field another farm can
/// refuse. The refusal carries up to three alternatives derived from this
/// farm's own oblast and name, shown as buttons that fill the field. An
/// empty list is a real answer: the refusal is said and nothing is invented.
///
/// ── Renaming a published page moves it at once ──
///
/// The old address stops answering in the same call, and it may be printed
/// on a card or sitting in a sent message. So a rename of a published page
/// asks first, and says that.
struct PublicAddressSheet: View {
    let current: String?
    let published: Bool
    let onClaimed: @MainActor (HandleClaim) async -> Void

    @State private var typed: String
    @State private var suggestions: [String] = []
    @State private var failure: String?
    @State private var saving = false
    @State private var confirmingRename = false
    @Environment(\.dismiss) private var dismiss

    init(current: String?, published: Bool, onClaimed: @escaping @MainActor (HandleClaim) async -> Void) {
        self.current = current
        self.published = published
        self.onClaimed = onClaimed
        _typed = State(initialValue: current ?? "")
    }

    private var trimmed: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { !trimmed.isEmpty && trimmed != current }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField("Адрес", text: $typed, prompt: .fieldPrompt("например pobeda"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if changed { ask() } }
                } header: {
                    SectionHeader("Адрес на страницата")
                } footer: {
                    SectionFooter(Self.rules)
                }

                if let failure {
                    Section {
                        Text(failure).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                typed = suggestion
                                failure = nil
                            }
                            .accessibilityHint("Попълва адреса")
                            .accessibilityInputLabels(A11y.spokenNames(suggestion))
                        }
                    } header: {
                        SectionHeader("Свободни адреси")
                    }
                }
            }
            .inlineTitle("Адрес")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Запази") { ask() }
                            .disabled(!changed)
                            .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .confirmationDialog("Промяна на адреса", isPresented: $confirmingRename, titleVisibility: .visible) {
                Button("Промени адреса", role: .destructive) { Task { await claim() } }
                    .accessibilityInputLabels(A11y.spokenNames("Промени адреса", "Change address"))
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            } message: {
                if let current {
                    Text(Self.renameWarning(FarmBrandAPI.displayAddress(handle: current)))
                }
            }
        }
    }

    /// A published page asks before it moves. Anything else goes straight
    /// through: there's no address anyone has yet.
    private func ask() {
        if published, current != nil {
            confirmingRename = true
        } else {
            Task { await claim() }
        }
    }

    private func claim() async {
        saving = true
        failure = nil
        defer { saving = false }
        do {
            let claim = try await FarmBrandAPI.claim(handle: trimmed)
            await onClaimed(claim)
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
            suggestions = FarmBrandAPI.suggestions(after: error) ?? []
        }
    }

    static let rules = "Между 3 и 40 знака. Написаното на кирилица се записва с латински букви: "
        + "„Победа“ става „pobeda“."

    static func renameWarning(_ old: String) -> String {
        "Страницата е публикувана на \(old). Със смяната старият адрес спира да се отваря веднага, "
            + "включително в изпратени връзки и отпечатани кодове."
    }
}
