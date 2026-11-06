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
struct NewWeedObservationSheet: View {
    let parcelID: String
    /// After a 201: the history reads itself again.
    let onSaved: () -> Void

    @State private var picked: Set<String> = []
    @State private var other = ""
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
            .inlineTitle(ParcelHistoryCopy.weedsAdd)
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
            .interactiveDismissDisabled(saving || !weeds.isEmpty)
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
            _ = try await ParcelHistoryAPI.createWeedObservation(
                parcelID: parcelID, NewWeedObservation(observedAt: .now, weeds: weeds))
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error) + " " + ParcelHistoryCopy.unsureNote
        }
    }
}
