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
///
/// ── And the yield (owner, 2026-11-06; agri-saas #2802) ──
///
/// "Реколти should include both the crop and the yield", for past years
/// too. A correction carries «Добив»; and the РЕКОЛТИ «+»'s «Добив»
/// (`forYield`) opens this form on the year: a year that has its crop row
/// edits it, one that hasn't makes one, with its crop. Typed as kg/дка OR
/// as the parcel's total in tonnes, the other worked out from its area
/// (owner: "Either one"); stored as kg/дка, so a re-measured parcel keeps
/// its rate.
struct NewCropSeasonSheet: View {
    let parcelID: String
    /// The season being corrected; nil for a new one.
    var editing: CropSeason? = nil
    /// The РЕКОЛТИ «+»'s «Добив»: the year's own row, with its yield.
    var forYield = false
    /// The parcel's seasons, for `forYield` to find the year's row.
    var seasons: [CropSeason] = []
    /// The parcel's area in HECTARES, for a total typed in tonnes.
    var areaHa: Double? = nil
    /// After the write: the history reads itself again.
    let onSaved: () -> Void

    @State private var year = NewCropSeasonSheet.thisYear
    @State private var crop: String?
    @State private var perDcaText = ""
    @State private var totalText = ""
    @State private var started = false
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focus: YieldField?
    @Environment(\.dismiss) private var dismiss

    private enum YieldField { case perDca, total }

    /// The harvest year now. The server bounds it by its UTC year, which
    /// differs from the phone's only in the hours around New Year, and only
    /// at the ends of a range that runs two years ahead.
    nonisolated static var thisYear: Int { Calendar(identifier: .gregorian).component(.year, from: .now) }

    /// Newest first: the server's two ahead, down to its 1900.
    nonisolated static var years: [Int] { Array((1900...(thisYear + 2)).reversed()) }

    /// The server's bound for a rate, kg per decare (`YIELD_OUT_OF_RANGE`).
    nonisolated static let maxYield: Decimal = 100_000

    /// The row this form writes to: the one being corrected, or for
    /// «Добив» the chosen year's own; nil makes a new one.
    private var target: CropSeason? {
        editing ?? (forYield ? seasons.first { $0.year == year } : nil)
    }

    private var showsYield: Bool { editing != nil || forYield }

    /// The rate typed, or worked out from the total; nil for nothing typed.
    private var yieldValue: Decimal? { OverheadSheet.amount(perDcaText) }

    /// Why «Запази» can't be pressed, in words; nil when it can.
    private var problem: String? {
        if crop == nil { return "Изберете култура." }
        if !perDcaText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = yieldValue, value >= 0, value <= Self.maxYield else {
                return "Добивът трябва да е число между 0 и 100 000 кг/дка."
            }
        }
        if forYield && editing == nil && yieldValue == nil { return "Въведете добива." }
        return nil
    }

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
                if showsYield { yieldSection }
                // A crop recorded outside the catalogue (free text, from the
                // web or an import) stays choosable when it is corrected.
                if let stored = target?.cropType, !CommodityName.cropCatalogue.contains(where: { $0.values.contains(stored) }) {
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
            .inlineTitle(editing != nil ? ParcelHistoryCopy.cropsEdit
                         : forYield ? ParcelHistoryCopy.yieldAdd : ParcelHistoryCopy.cropsAdd)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(problem != nil || saving)
                        .accessibilityHint(problem ?? "")
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving || (editing == nil && crop != nil))
            .onAppear {
                guard !started else { return }
                started = true
                if let editing { year = editing.year }
                load(target)
            }
            // «Добив»: another year is another row, its crop and yield.
            .onChange(of: year) {
                if forYield && editing == nil { load(target) }
            }
        }
    }

    /// «Добив»: kg/дка, and the parcel's total in tonnes when its area is
    /// known. Either is typed; the other follows.
    private var yieldSection: some View {
        Section {
            FieldRow("кг/дка", spoken: "Добив, килограма на декар") {
                TextField("кг/дка", text: $perDcaText, prompt: .fieldPrompt("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .perDca)
            }
            if let decares = decares {
                FieldRow("Общо, т", spoken: "Добив от целия парцел, тона") {
                    TextField("Общо, т", text: $totalText, prompt: .fieldPrompt("0"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .total)
                }
                .onChange(of: totalText) {
                    guard focus == .total else { return }
                    perDcaText = OverheadSheet.amount(totalText).map { Self.text($0 * 1000 / decares) } ?? ""
                }
            }
        } header: {
            SectionHeader("Добив")
        } footer: {
            SectionFooter {
                if let decares {
                    Text("Въведете килограма на декар или общо за парцела (\(Self.text(decares)) дка); другото се изчислява.")
                } else {
                    Text("Килограма на декар.")
                }
            }
        }
        .onChange(of: perDcaText) {
            guard focus != .total, let decares else { return }
            totalText = yieldValue.map { Self.text($0 * decares / 1000) } ?? ""
        }
    }

    /// The parcel's area in decares (1 ha = 10 дка), when known.
    private var decares: Decimal? {
        guard let areaHa, areaHa > 0 else { return nil }
        return Decimal(areaHa) * 10
    }

    /// Up to two places, the comma, no grouping: as a farmer types it.
    private static func text(_ value: Decimal) -> String {
        var exact = value, rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 2, .plain)
        return OverheadSheet.fieldText(rounded)
    }

    /// The form as `season` has it, or the year's blank when there is none.
    private func load(_ season: CropSeason?) {
        crop = season?.cropType ?? (forYield ? crop : nil)
        perDcaText = season?.yieldKgPerDca.map { Self.text($0.value) } ?? ""
        if let decares, let value = yieldValue { totalText = Self.text(value * decares / 1000) } else { totalText = "" }
    }

    private func save() async {
        guard let crop, problem == nil, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            if let target {
                let change = CropSeasonChange(from: target, year: year, crop: crop,
                                              yield: yieldValue, keepsYield: !showsYield)
                // Nothing changed: nothing sent (the server refuses an empty
                // correction, and would audit one that happened).
                guard !change.isEmpty else { return dismiss() }
                try await ParcelHistoryAPI.updateCropSeason(parcelID: parcelID, seasonID: target.id, change)
            } else {
                _ = try await ParcelHistoryAPI.createCropSeason(
                    parcelID: parcelID,
                    NewCropSeason(year: year, cropType: crop, yieldKgPerDca: showsYield ? yieldValue : nil))
            }
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error) + " " + ParcelHistoryCopy.unsureNote
        }
    }
}
