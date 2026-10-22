import SwiftUI

/// «Ново мероприятие»: the owner's two-step treatment record, the same on the
/// phone and the web (agrent-ios#293; agri-saas #1740).
///
///   1. What was done — every field the ДНЕВНИК prints (`TreatmentFieldsView`).
///   2. «Напред»: the crop at the top right, its parcels on a map and in a
///      list, the treated ones ticked (`TreatmentPlaceView`).
///   3. «Продължи»: the whole treatment read back, with the amount of
///      product and the end of the quarantine period (`TreatmentCheckView`,
///      #362, owner 2026-10-20 — PRZ's check screen).
///   4. «Добави»: saved, with «Изтегли PDF» — the ДНЕВНИК pages for this
///      entry alone (`TreatmentSavedView`). With no signal, kept on the
///      phone and sent later, under the same key (#324).
///
/// Modelled on PRZ's «Добавяне на мероприятие» (owner, 2026-10-13): spraying
/// and fertilising, done work only. It REPLACES the journal's free-form
/// «Нов запис»; the entries that form wrote stay readable.
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

    /// The save's `Idempotency-Key`, and an earlier save not yet answered —
    /// see `TreatmentAttempt`.
    @State private var attempt = TreatmentAttempt()

    /// Step three carries what it reads back, as it was when «Продължи» was
    /// pressed (#384). It used to be a separate `@State`, set just before the
    /// push, and the destination could be built in the same update with it
    /// still nil: an empty page with only a back arrow. Online, a network
    /// answer arriving a moment later redrew the destination and hid it.
    /// Offline, and under the UI-test seam, nothing redraws, so the page
    /// stayed empty (the owner's phone, 2026-10-21; A11yShots 20b). In the
    /// path itself it can't be missing.
    /// `.map` is the saved screen's «Виж на картата» (#399): the parcels it
    /// already holds, on a map.
    enum Step: Hashable { case place, check(Checking), map([TreatmentPlace.Field], TreatmentDraft.Kind) }

    struct Checking: Hashable {
        let record: TreatmentRecord
        let fields: [TreatmentPlace.Field]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let saved {
                    TreatmentSavedView(saved: saved, recorder: recorder,
                                       onShowMap: { path.append(.map(saved.fields, saved.record.kind)) }) { dismiss() }
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
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .place:
                    TreatmentPlaceView(store: place, kind: draft.kind, cropKey: $cropKey, chosen: $chosen,
                                       treatedText: $draft.treatedText,
                                       failure: failure, retryCrops: { await loadPlace() }) { fields in
                        proceed(fields)
                    }
                case .map(let fields, let kind):
                    TreatmentMapView(fields: fields, title: TreatmentMapView.title(for: kind))
                case .check(let checking):
                    TreatmentCheckView(
                        record: checking.record, fields: checking.fields, cropLabel: cropLabel,
                        doseUnitSymbol: draft.doseUnit?.symbol, saving: saving, failure: failure,
                        onEdit: {
                            // Back to the fields, everything kept: the
                            // parcels stay ticked for the way forward.
                            failure = nil
                            path = []
                        },
                        onAdd: { Task { await save(checking.fields) } },
                        onCancel: { dismiss() })
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .writeFeedback(feedback)
        // The parcels are read as step one opens — usually in hand by «Напред»
        // — and from here, so going back from step two does not cancel it.
        .task { await loadPlace() }
        // A refusal is about what was chosen when it came; a new choice
        // clears it rather than leaving it over a different entry.
        .onChange(of: chosen) { _, _ in failure = nil }
        .onChange(of: cropKey) { _, _ in failure = nil }
    }

    /// The farm's crops — and, when it grows one, that crop chosen for the
    /// person and its parcels read now, so they are in hand by «Напред». Step
    /// two's «Опитайте отново» runs this again after a failed read, so a
    /// retry chooses the lone crop as the first read would have.
    private func loadPlace() async {
        await place.load()
        if cropKey == nil, let crops = place.state.value, crops.count == 1 {
            cropKey = crops[0].key
            await place.loadFields(for: crops[0])
        }
    }

    private var cropLabel: String? { place.state.value?.first { $0.key == cropKey }?.label }

    /// «Продължи»: on to the check with the treatment as it stands, or the
    /// first thing in its way, said on step two. «Напред» was allowed with
    /// the catalogue not yet in hand, a name then counting as new; once it
    /// loads, the name may turn out to be a sample or the wrong kind.
    private func proceed(_ fields: [TreatmentPlace.Field]) {
        guard let record = TreatmentRecord.make(draft, catalogue: reference.items.value, fields: fields) else {
            failure = draft.problems(catalogue: reference.items.value).first?.text
                ?? TreatmentDraft.treatedProblem(draft.treatedText, for: fields)
                ?? "Изберете поне един парцел."
            return
        }
        failure = nil
        path.append(.check(Checking(record: record, fields: fields)))
    }

    private func save(_ fields: [TreatmentPlace.Field]) async {
        guard !saving else { return }
        // Asked again, not taken from the check: the catalogue may have
        // loaded since «Продължи». Said here, never an «Добави» that does
        // nothing.
        guard let record = TreatmentRecord.make(draft, catalogue: reference.items.value, fields: fields) else {
            failure = draft.problems(catalogue: reference.items.value).first?.text
                ?? "Изберете поне един парцел."
            return
        }
        saving = true
        failure = nil
        defer { saving = false }
        // On a copy: a mutating call cannot stay open on the view's own
        // state across an `await`.
        var attempt = attempt
        let outcome = await attempt.save(
            record, fields: fields, cropLabel: cropLabel,
            entered: draft, with: recorder)
        self.attempt = attempt
        switch outcome {
        case .saved(let kept, let changeLost):
            feedback.saved()
            saved = .init(handle: kept.key, record: kept.record, fields: kept.fields,
                          cropLabel: kept.cropLabel, changeLost: changeLost)
            // The saved screen replaces the steps: there is no going back to
            // edit what is already recorded.
            path = []
            onSaved()
        case .queued(let kept, let afterUpdate):
            // Kept, and on its way (#324): the same screen, saying it waits.
            // No going back to edit it either — it is in the outbox under
            // its key, and a changed entry would be a second treatment. The
            // journal behind the sheet shows it waiting.
            feedback.saved()
            saved = .init(handle: kept.key, record: kept.record, fields: kept.fields,
                          cropLabel: kept.cropLabel, waiting: afterUpdate ? .update : .signal)
            path = []
            onSaved()
        case .failed(let text):
            failure = text
            feedback.refused()
        }
    }
}
