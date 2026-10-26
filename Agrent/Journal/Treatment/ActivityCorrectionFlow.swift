import SwiftUI

/// «Коригирай» on pruning, cultivation or a harvest (#439; agri-saas #2375):
/// the activity as recorded, read from the server; its day, a harvest's
/// total and its parcels (#447); «Проверка» with each change before and
/// after; «Запази».
///
/// A treatment's correction, made small (`TreatmentCorrectionFlow`): it
/// starts from `GET …/definition` for the version, as a correction made
/// against a version can't silently overwrite someone else's (409
/// `STALE_DATA`), and reads its changes back on the same «Проверка».
struct ActivityCorrectionFlow: View {
    let handle: String
    /// The corrected activity, for the screen underneath to show at once.
    /// No haptic, as on a treatment: the entry showing the new values is the
    /// confirmation, and a refusal stays on «Проверка», said and in red.
    let onCorrected: (ActivityCorrection.Saved) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ActivityCorrection.Draft?
    /// The activity's blocks and their parcels, read once the definition
    /// names them, and any other block the person adds.
    @State private var blocks = TreatmentBlocks()
    @State private var loadFailure: String?
    @State private var path: [Step] = []
    @State private var saving = false
    @State private var failure: String?
    @State private var stale = false

    enum Step: Hashable { case check }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let draft = Binding($draft) {
                    ActivityCorrectionForm(draft: draft, blocks: blocks,
                                           onNext: { failure = nil; path = [.check] },
                                           onCancel: { dismiss() })
                } else if let loadFailure {
                    ErrorState(message: loadFailure) { await load() }
                        .inlineTitle(TreatmentCorrectionFlow.title)
                        .toolbar { cancel }
                } else {
                    ProgressView()
                        .accessibilityLabel("Зареждане")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .inlineTitle(TreatmentCorrectionFlow.title)
                        .toolbar { cancel }
                }
            }
            .navigationDestination(for: Step.self) { _ in
                if let draft {
                    TreatmentCorrectionCheckView(
                        changes: draft.changes, saving: saving, failure: failure, stale: stale,
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
            draft = ActivityCorrection.Draft(try await ActivityCorrectionAPI.definition(handle))
            // The form is up by now; the blocks' other parcels join the list
            // when they come, unticked.
            if let ids = draft?.blockIDs {
                await blocks.load(blockIDs: ids)
                draft?.offer(blocks.blocks)
            }
        } catch {
            loadFailure = UserMessage.text(for: error)
        }
    }

    /// After someone else's correction: their values, and back to the form.
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
            let corrected = try await ActivityCorrectionAPI.correct(
                handle, draft.body, version: draft.original.version)
            JournalChanges.shared.changed()
            onCorrected(ActivityCorrection.Saved(definition: corrected,
                                                 parcelsChanged: draft.changed.contains(.parcels)))
            dismiss()
        } catch APIClient.APIError.conflict {
            stale = true
            failure = TreatmentCorrection.staleText
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
