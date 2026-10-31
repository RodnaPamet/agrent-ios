import SwiftUI

/// A file's last step before it goes up: its name, and what will happen to
/// it (owner, 2026-10-30: a scan asks for its name, prefilled with the
/// date, the keyboard up).
///
/// ── The warning before an upload ──
///
/// With the Drive copy off (or Google not connected) and a period other
/// than «Без срок», the document will be deleted from Agrent with no copy
/// anywhere. The owner asked for that to be said before the upload, so it
/// is said here, with the day, and «Качи» still uploads.
struct DocumentUploadSheet: View {
    let file: DocumentUpload
    let settings: DocumentSettings?
    let store: DocumentsStore

    @State private var name: String
    @FocusState private var naming: Bool
    @Environment(\.dismiss) private var dismiss

    init(file: DocumentUpload, settings: DocumentSettings?, store: DocumentsStore) {
        self.file = file
        self.settings = settings
        self.store = store
        _name = State(initialValue: file.suggestedName)
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField("Име", text: $name, prompt: .fieldPrompt("Име на документа"))
                        .focused($naming)
                        .submitLabel(.done)
                        .accessibilityLabel("Име на документа")
                } header: {
                    SectionHeader("Име")
                } footer: {
                    SectionFooter(A11y.sentence([file.kind.label, DocumentSize.text(Int64(file.data.count))]))
                }

                if let warning = UploadWarning.text(settings) {
                    Section {
                        Label {
                            Text(warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundStyle(Palette.warning)
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .inlineTitle("Нов документ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(store.uploading != nil)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.uploading != nil {
                        ProgressView()
                    } else {
                        Button("Качи") {
                            Task { if await store.upload(file, as: name) { dismiss() } }
                        }
                        .fontWeight(.semibold)
                        .accessibilityInputLabels(A11y.Spoken.upload)
                    }
                }
            }
            .interactiveDismissDisabled(store.uploading != nil)
            .onAppear { naming = true }
        }
    }
}

/// The warning's words, kept out of the view so they can be tested.
enum UploadWarning {
    static func text(_ settings: DocumentSettings?, now: Date = Date()) -> String? {
        guard let settings, settings.uploadsExpireWithoutCopy,
              let day = settings.retention.expiry(from: now) else { return nil }
        return "Документът ще бъде изтрит от Agrent на \(BgDate.fullEndingSentence(day)) "
            + "Копие в Google Drive не се пази, докато «Копие в Google Drive» е изключено."
    }
}
