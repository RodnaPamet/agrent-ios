import SwiftUI

/// «Запиши култура» (owner, 2026-11-06): what a parcel grew in a harvest
/// year, from the «+» on its history's РЕКОЛТИ.
///
/// ── The web's form, field for field ──
///
/// `AddCropSeasonModal`: «Стопанска година», with the web's hint that an
/// autumn-sown crop belongs to the FOLLOWING year's harvest, and «Култура»
/// from the parcel catalogue (`CommodityName.cropCatalogue`). No dates and
/// no notes, as there: the archive's job is "what grew here which year",
/// and a back-filled year is rarely remembered to the day.
///
/// ── Back-fillable, on purpose ──
///
/// The years run from two ahead (the server's `YEARS_AHEAD`) back to its
/// `MIN_YEAR`. An archive whose first entry can only be today is not an
/// archive.
///
/// ── Sent once ──
///
/// The route takes no `Idempotency-Key` (`NewCropSeason`), so nothing here
/// retries, and a failure says the season may exist before it invites the
/// second tap that would make it twice.
///
/// ── And a correction (#542, owner 2026-11-06) ──
///
/// Opened on a РЕКОЛТИ row (`editing`), the same form, filled in; «Запази»
/// sends only what changed (`CropSeasonChange`), and nothing at all when
/// nothing did.
struct NewCropSeasonSheet: View {
    let parcelID: String
    /// The season being corrected; nil for a new one.
    var editing: CropSeason? = nil
    /// After the write: the history reads itself again.
    let onSaved: () -> Void

    @State private var year = NewCropSeasonSheet.thisYear
    @State private var crop: String?
    @State private var started = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    /// The harvest year now. The server bounds it by its UTC year, which
    /// differs from the phone's only in the hours around New Year, and only
    /// at the ends of a range that runs two years ahead.
    nonisolated static var thisYear: Int { Calendar(identifier: .gregorian).component(.year, from: .now) }

    /// Newest first: the server's two ahead, down to its 1900.
    nonisolated static var years: [Int] { Array((1900...(thisYear + 2)).reversed()) }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    Picker(ParcelHistoryCopy.fieldYear, selection: $year) {
                        ForEach(Self.years, id: \.self) { year in
                            Text(verbatim: String(year)).tag(year)
                        }
                    }
                    .pickerStyle(.wheel)
                } header: {
                    SectionHeader(ParcelHistoryCopy.fieldYear)
                } footer: {
                    SectionFooter { Text(ParcelHistoryCopy.fieldYearHint) }
                }
                // A crop recorded outside the catalogue (free text, from the
                // web or an import) stays choosable when it is corrected.
                if let stored = editing?.cropType, !CommodityName.cropCatalogue.contains(where: { $0.values.contains(stored) }) {
                    Section {
                        ChoiceRow(title: CommodityName.freeText(stored) ?? stored, chosen: crop == stored) {
                            crop = stored
                        }
                    } header: {
                        SectionHeader("Записана")
                    }
                }
                ForEach(CommodityName.cropCatalogue, id: \.season) { group in
                    Section {
                        ForEach(group.values, id: \.self) { value in
                            ChoiceRow(title: CommodityName.freeText(value) ?? value, chosen: crop == value) {
                                crop = value
                            }
                        }
                    } header: {
                        SectionHeader(group.season)
                    }
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(Palette.error)
                    }
                }
            }
            .inlineTitle(editing == nil ? ParcelHistoryCopy.cropsAdd : ParcelHistoryCopy.cropsEdit)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(crop == nil || saving)
                        .accessibilityHint(crop == nil ? "Изберете култура." : "")
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving || (editing == nil && crop != nil))
            .onAppear {
                guard !started, let editing else { return }
                started = true
                year = editing.year
                crop = editing.cropType
            }
        }
    }

    private func save() async {
        guard let crop, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            if let editing {
                let change = CropSeasonChange(from: editing, year: year, crop: crop)
                // Nothing changed: nothing sent (the server refuses an empty
                // correction, and would audit one that happened).
                guard !change.isEmpty else { return dismiss() }
                try await ParcelHistoryAPI.updateCropSeason(parcelID: parcelID, seasonID: editing.id, change)
            } else {
                _ = try await ParcelHistoryAPI.createCropSeason(
                    parcelID: parcelID, NewCropSeason(year: year, cropType: crop))
            }
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error) + " " + ParcelHistoryCopy.unsureNote
        }
    }
}
