import SwiftUI

/// «Ново мероприятие», step three: everything that will be recorded and what
/// it adds up to, before «Добави» (agrent-ios#362).
///
/// PRZ's second screen (owner, 2026-10-20): after «Продължи» the farmer
/// reads the treatment back with the amount of product it took and the end
/// of the quarantine period, then adds it or goes back to correct it. A
/// treatment is a filed record, and a dose typed as 4 instead of 0,4 shows
/// up here as ten times the product they actually poured.
struct TreatmentCheckView: View {
    let record: TreatmentRecord
    let fields: [TreatmentPlace.Field]
    let cropLabel: String?
    /// The dose unit as the form chose it. nil only if the catalogue went
    /// away under the form, and then the amount isn't worked out.
    let doseUnitSymbol: String?
    let saving: Bool
    let failure: String?
    /// «Редактирай данните»: back to the fields, everything kept.
    let onEdit: () -> Void
    let onAdd: () -> Void
    /// «Отказ»: the whole entry abandoned, as on step one — PRZ's third
    /// button on this screen.
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var total: TreatmentPlace.Total { TreatmentPlace.total(fields, treated: record.treatedAreas) }

    private var amount: TreatmentCheck.Amount? {
        doseUnitSymbol.flatMap { TreatmentCheck.amount(dose: record.dose, unitSymbol: $0, area: total.area) }
    }

    /// The blocks the parcels are in, in the order the list showed them.
    private var blocks: [String] {
        var seen = Set<String>()
        return fields.map(\.blockName).filter { seen.insert($0).inserted }
    }

    private var areaWord: String { Self.areaWord(record) }

    /// «Площ» on other work, which treats nothing (#439).
    nonisolated static func areaWord(_ record: TreatmentRecord) -> String {
        if record.activity != nil { return "Площ" }
        return record.kind == .spray ? "Третирана площ" : "Наторена площ"
    }

    /// «1 250 кг», the harvest as typed.
    nonisolated static func kgText(_ kg: Decimal) -> String {
        "\(kg.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic).locale(BgDate.locale))) кг"
    }

    private var dose: String {
        let number = Num.text(NSDecimalNumber(decimal: record.dose).doubleValue)
        return doseUnitSymbol.map { "\(number) \($0)" } ?? number
    }

    private var doseSpoken: String {
        let number = Num.text(NSDecimalNumber(decimal: record.dose).doubleValue)
        guard let symbol = doseUnitSymbol else { return number }
        return "\(number) \(JournalTreatment.rateUnitNames[symbol] ?? symbol)"
    }

    var body: some View {
        PageForm {
            Section {
                ValueRow("Вид") { Text(record.activity?.label ?? record.kind.label) }
                ValueRow("Дата") { Text(BgDate.full(record.date)) }
                if record.activity == nil {
                    ValueRow(record.kind.inputLabel) { Text(record.productName) }
                    if let pest = record.pest { ValueRow("Вредител") { Text(pest) } }
                    ValueRow("Доза") { Text(dose).accessibilityLabel(doseSpoken) }
                    if let stage = record.phenophase { ValueRow("Фенофаза/BBCH") { Text(stage) } }
                    if let technique = record.technique { ValueRow("Техника") { Text(technique.label) } }
                }
                if let kg = record.harvestKg {
                    ValueRow("Прибрано") { Text(Self.kgText(kg)) }
                }
            }
            Section {
                if let cropLabel { ValueRow("Култура") { Text(cropLabel) } }
                ValueRow(blocks.count == 1 ? "Блок" : "Блокове") { Text(blocks.joined(separator: ", ")) }
                ValueRow("Парцели") { Text(String(total.parcels)) }
                ValueRow(areaWord) { Text(total.area.text).accessibilityLabel(total.area.spoken) }
            } header: {
                SectionHeader("Къде")
            } footer: {
                // Other work has no «Изчислено» to carry the note (#439).
                SectionFooter(record.activity == nil ? "" : Self.withoutAreaNote(total.withoutArea))
            }
            // The amount of product and the end of the period: a treatment's.
            if record.activity == nil {
            Section {
                if let amount {
                    ValueRow(record.kind == .spray ? "Нужен препарат" : "Нужен тор") {
                        Text(amount.text).accessibilityLabel(amount.spoken)
                    }
                } else {
                    Text(Self.noAmount(area: total.area))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let days = record.quarantineDays {
                    ValueRow("Карантинен срок") { Text(Plural.bg(days, "ден", "дни")) }
                    if let day = TreatmentCheck.earliestHarvest(after: record.date, days: days) {
                        ValueRow("Най-ранна дата за прибиране") { Text(BgDate.full(day)) }
                    }
                }
            } header: {
                SectionHeader("Изчислено")
            } footer: {
                SectionFooter(Self.withoutAreaNote(total.withoutArea))
            }
            }
            if let failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // At the accessibility sizes the way back scrolls with the
            // page: two large buttons pinned under it would leave the
            // treatment they confirm a sliver to be read in.
            if typeSize.isAccessibilitySize {
                Section { editButton }
            }
        }
        .safeAreaInset(edge: .bottom) { actions }
        .inlineTitle("Проверка")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отказ", action: onCancel)
                    .disabled(saving)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            }
        }
        // A save under way is not abandoned by a swipe back, and its refusal
        // does not land on a screen that has gone.
        .navigationBarBackButtonHidden(saving)
        // Said, not only drawn: the refusal replaces the spinner under the
        // cursor.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            var line = AttributedString(now)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
    }

    /// Said where «Добави» is decided. Until 2026-10-24 it went on: «След
    /// записване вписването в ДНЕВНИКА не може да се редактира.» The owner
    /// made recorded treatments correctable that day («Коригирай», #392), so
    /// the second sentence went, here and on the website's review step
    /// (agri-saas #2174), in the same release: the two surfaces don't word
    /// one rule two ways.
    nonisolated static let finalNote = "Проверете данните."

    private var actions: some View {
        VStack(spacing: 8) {
            Text(Self.finalNote)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAdd) {
                if saving {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Записване")
                } else {
                    Text("Добави").frame(maxWidth: .infinity)
                }
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(saving)
            .accessibilityInputLabels(A11y.Spoken.add)

            if !typeSize.isAccessibilitySize { editButton }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Text("Редактирай данните").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(saving)
        .accessibilityInputLabels(A11y.Spoken.editEntry)
    }

    /// Why there is no amount, rather than a blank: no area to multiply, or
    /// a dose that isn't per area.
    nonisolated static func noAmount(area: Area) -> String {
        area.decares > 0
            ? "Нужното количество не се изчислява: дозата не е на декар."
            : "Нужното количество не се изчислява: избраните парцели са без площ."
    }

    /// The area and the amount are never presented as complete when they
    /// are not.
    nonisolated static func withoutAreaNote(_ count: Int) -> String {
        switch count {
        case 0: ""
        case 1: "1 парцел е без площ и не е включен в площта и в количеството."
        default: "\(count) парцела са без площ и не са включени в площта и в количеството."
        }
    }
}
