import SwiftUI

/// «Запиши плевели» (owner, 2026-11-06): which weeds are in a parcel today,
/// from the «+» on its history's ПЛЕВЕЛИ.
///
/// ── The web's form ──
///
/// `AddWeedObservationModal`: the thirteen of the catalogue to tick, and
/// «Друго» for one it doesn't carry, sent as ONE list that the server splits
/// (`NewWeedObservation`). Observed now, as there: the form is filled in
/// standing in the field. Grouped as the task's closing form groups them,
/// grasses first (`CloseTaskSheet`), the division that decides the
/// herbicide.
///
/// «Друго» takes several, comma-separated, as the web's box does.
///
/// ── The parcel's route, not the task's ──
///
/// There are two weed-observation POSTs, the same body under two parents.
/// This is the parcel's (`/agro/parcels/{id}/weed-observations`); the task's
/// files the observation against a field operation, which this isn't.
///
/// ── Sent once ──
///
/// No `Idempotency-Key` is documented for it (`NewCropSeason`), so nothing
/// retries, and a failure says it may have been recorded.
///
/// ── And a correction (#542, owner 2026-11-06) ──
///
/// Opened on a ПЛЕВЕЛИ row (`editing`), the same form, its weeds ticked and
/// the rest in «Друго»; «Запази» sends the list only when it changed. The
/// day it was seen is kept.
struct NewWeedObservationSheet: View {
    let parcelID: String
    /// The observation being corrected; nil for a new one.
    var editing: WeedObservation? = nil
    /// After the write: the history reads itself again.
    let onSaved: () -> Void

    @State private var picked: Set<String> = []
    @State private var other = ""
    @State private var started = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    /// The catalogue's ticked, in its order, then «Друго»'s.
    private var weeds: [String] {
        NewWeedObservation.cleaned(
            WeedCatalogue.binomials.filter(picked.contains) + other.split(separator: ",").map(String.init))
    }

    var body: some View {
        NavigationStack {
            PageForm {
                group("Житен плевел", WeedCatalogue.binomials.filter(WeedCatalogue.grasses.contains))
                group("Широколистен плевел", WeedCatalogue.binomials.filter { !WeedCatalogue.grasses.contains($0) })
                Section {
                    TextField(ParcelHistoryCopy.otherWeed, text: $other,
                              prompt: .fieldPrompt("Вид, който не е в списъка"))
                } header: {
                    SectionHeader(ParcelHistoryCopy.otherWeed)
                } footer: {
                    SectionFooter {
                        if let failure {
                            Text(failure).foregroundStyle(Palette.error)
                        } else {
                            Text(ParcelHistoryCopy.fieldWeedsHint)
                        }
                    }
                }
            }
            .inlineTitle(editing == nil ? ParcelHistoryCopy.weedsAdd : ParcelHistoryCopy.weedsEdit)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(weeds.isEmpty || saving)
                        .accessibilityHint(weeds.isEmpty ? "Изберете поне един плевел." : "")
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving || (editing == nil && !weeds.isEmpty))
            .onAppear {
                guard !started, let editing else { return }
                started = true
                let catalogue = Set(WeedCatalogue.binomials)
                picked = Set(editing.weedKeys.filter(catalogue.contains))
                other = (editing.weedKeys.filter { !catalogue.contains($0) } + editing.otherWeeds)
                    .joined(separator: ", ")
            }
        }
    }

    private func group(_ title: String, _ keys: [String]) -> some View {
        Section {
            ForEach(keys, id: \.self) { key in
                ChoiceRow(title: WeedCatalogue.rowName(for: key), chosen: picked.contains(key)) {
                    if picked.contains(key) { picked.remove(key) } else { picked.insert(key) }
                }
            }
        } header: {
            SectionHeader(title)
        }
    }

    private func save() async {
        let weeds = weeds
        guard !weeds.isEmpty, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            if let editing {
                let change = WeedObservationChange(from: editing, weeds: weeds)
                guard !change.isEmpty else { return dismiss() }
                try await ParcelHistoryAPI.updateWeedObservation(
                    parcelID: parcelID, observationID: editing.id, change)
            } else {
                _ = try await ParcelHistoryAPI.createWeedObservation(
                    parcelID: parcelID, NewWeedObservation(observedAt: .now, weeds: weeds))
            }
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error) + " " + ParcelHistoryCopy.unsureNote
        }
    }
}
