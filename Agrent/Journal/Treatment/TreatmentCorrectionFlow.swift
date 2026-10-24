import SwiftUI

/// «Коригирай» (agrent-ios #392, owner 2026-10-24): the recorded treatment,
/// read from the server and prefilled; «Проверка» with each change before
/// and after; «Запази».
///
/// Two steps where «Ново мероприятие» has three: the parcel step is left
/// out because nothing on it can be corrected yet. The parcels are shown,
/// locked, on the first.
///
/// The form starts from `GET …/definition`, not from the journal row: the
/// row carries no version, and a correction made against a version is the
/// one that can't silently overwrite someone else's (409 `STALE_DATA`).
struct TreatmentCorrectionFlow: View {
    let handle: String
    /// The journal row, for the dose as it writes it.
    let row: JournalTreatment
    /// The corrected treatment, for the screen underneath to show at once.
    ///
    /// No haptic either way (`WriteFeedback`'s sites): the sheet closes onto
    /// the entry showing the corrected values, which is its own
    /// confirmation, and a refusal stays on «Проверка», said and in red.
    let onCorrected: (TreatmentDefinition) -> Void

    static let title = "Корекция"

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TreatmentCorrection.Draft?
    @State private var loadFailure: String?
    /// The way to «Проверка», by value: what it reads back is the draft,
    /// which is in hand before the push (#384's empty page can't happen).
    @State private var path: [Step] = []
    @State private var saving = false
    @State private var failure: String?
    @State private var stale = false

    enum Step: Hashable { case check }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let draft = Binding($draft) {
                    TreatmentCorrectionForm(draft: draft, doseText: row.doseText, doseSpoken: row.doseSpoken,
                                            onNext: { failure = nil; path = [.check] },
                                            onCancel: { dismiss() })
                } else if let loadFailure {
                    ErrorState(message: loadFailure) { await load() }
                        .inlineTitle(Self.title)
                        .toolbar { cancel }
                } else {
                    ProgressView()
                        .accessibilityLabel("Зареждане")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .inlineTitle(Self.title)
                        .toolbar { cancel }
                }
            }
            .navigationDestination(for: Step.self) { _ in
                if let draft {
                    TreatmentCorrectionCheckView(
                        draft: draft, saving: saving, failure: failure, stale: stale,
                        onSave: { Task { await save() } },
                        onReload: { Task { await reload() } },
                        onCancel: { dismiss() })
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task { await load() }
    }

    private var cancel: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Отказ") { dismiss() }
                .accessibilityInputLabels(A11y.Spoken.cancel)
        }
    }

    private func load() async {
        loadFailure = nil
        do {
            draft = TreatmentCorrection.Draft(try await TreatmentCorrectionAPI.definition(handle))
        } catch {
            loadFailure = UserMessage.text(for: error)
        }
    }

    /// After someone else's correction: their values, from the server, and
    /// back to the form. This one's changes are dropped, as the sentence
    /// that offered this said.
    private func reload() async {
        path = []
        stale = false
        failure = nil
        draft = nil
        await load()
    }

    private func save() async {
        guard let draft, !saving, draft.problems().isEmpty else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            let corrected = try await TreatmentCorrectionAPI.correct(
                handle, draft.body, version: draft.original.version)
            // The list behind the entry reads again; the entry's own screen
            // shows the corrected values from `onCorrected` until then.
            JournalChanges.shared.changed()
            onCorrected(corrected)
            dismiss()
        } catch APIClient.APIError.conflict {
            stale = true
            failure = TreatmentCorrection.staleText
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
