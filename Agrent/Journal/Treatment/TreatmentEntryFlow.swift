import SwiftUI

/// «Ново мероприятие»: the owner's two-step treatment record, the same on the
/// phone and the web (agrent-ios#293; agri-saas #1740).
///
///   1. What was done — every field the ДНЕВНИК prints (`TreatmentFieldsView`).
///   2. «Напред»: the crop at the top right, its parcels on a map and in a
///      list, the treated ones ticked (`TreatmentPlaceView`).
///   3. «Запази»: saved, with «Изтегли PDF» — the ДНЕВНИК pages for this
///      entry alone (`TreatmentSavedView`).
///
/// Modelled on PRZ's «Добавяне на мероприятие» (owner, 2026-10-13): spraying
/// and fertilising, done work only, replacing the journal's free-form
/// «Нов запис» once the server can keep it — see `TreatmentRecorder`.
struct TreatmentEntryFlow: View {
    let recorder: TreatmentRecorder
    /// The journal refreshes behind the sheet once an entry is saved.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = TreatmentDraft()
    @State private var reference = OperationReferenceStore()
    @State private var place = TreatmentPlaceStore()
    @State private var path: [Step] = []
    @State private var cropKey: String?
    @State private var chosen: Set<String> = []
    @State private var saving = false
    @State private var failure: String?
    @State private var saved: TreatmentSavedView.Saved?
    @State private var feedback = WriteFeedback()

    /// The save's `Idempotency-Key` — see `TreatmentAttempt`.
    @State private var attempt = TreatmentAttempt()

    enum Step: Hashable { case place }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let saved {
                    TreatmentSavedView(saved: saved, recorder: recorder) { dismiss() }
                } else {
                    TreatmentFieldsView(draft: $draft, reference: reference) {
                        path.append(.place)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Отказ") { dismiss() }
                                .disabled(saving)
                                .accessibilityInputLabels(A11y.Spoken.cancel)
                        }
                    }
                }
            }
            .navigationDestination(for: Step.self) { _ in
                TreatmentPlaceView(store: place, kind: draft.kind, cropKey: $cropKey, chosen: $chosen,
                                   saving: saving, failure: failure) { fields in
                    Task { await save(fields) }
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .writeFeedback(feedback)
        // The parcels are read as step one opens — usually in hand by «Напред»
        // — and from here, so going back from step two does not cancel it.
        .task {
            await place.load()
            // Chosen for the person when the farm grows one crop.
            if cropKey == nil, let crops = place.state.value, crops.count == 1 { cropKey = crops[0].key }
        }
        // A refusal is about what was chosen when it came; a new choice
        // clears it rather than leaving it over a different entry.
        .onChange(of: chosen) { _, _ in failure = nil }
        .onChange(of: cropKey) { _, _ in failure = nil }
    }

    private func save(_ fields: [TreatmentPlace.Field]) async {
        guard !saving else { return }
        // «Напред» was allowed with the catalogue not yet in hand, a name then
        // counting as new; once it loads, the name may turn out to be a sample
        // or the wrong kind. Said here, never a «Запази» that does nothing.
        guard let record = TreatmentRecord.make(draft, catalogue: reference.items.value, fields: fields) else {
            failure = draft.problems(catalogue: reference.items.value).first?.text
                ?? "Изберете поне един парцел."
            return
        }
        let key = attempt.key(for: draft, parcels: fields.map(\.id))
        saving = true
        failure = nil
        defer { saving = false }
        do {
            let id = try await recorder.record(record, idempotencyKey: key)
            feedback.saved()
            saved = .init(entryID: id, record: record, fields: fields,
                          cropLabel: place.state.value?.first { $0.key == cropKey }?.label)
            // The saved screen replaces the steps: there is no going back to
            // edit what is already recorded.
            path = []
            onSaved()
        } catch {
            failure = UserMessage.text(for: error)
            feedback.refused()
        }
    }
}
