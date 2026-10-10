import SwiftUI

/// The «Култура» fields of «Нов разход» (#245): one crop's costs, a rate per
/// decare each, a section per category. The rules are `CropSheet`'s; this
/// draws them, and the total they come to over the crop's land.
struct CropFields: View {
    @Binding var sheet: CropSheet
    let crop: CropChoice
    /// The sheet's currency, as typed: the rate's unit.
    let currency: String
    /// Sent, and in flight or its answer lost: nothing on it is edited.
    let locked: Bool

    var body: some View {
        Group {
            ForEach($sheet.groups) { $group in
                Section {
                    ForEach($group.rows) { $row in
                        rowView($row, in: group)
                    }
                    // A row of its own can go; the last one of a group stays,
                    // since a group with no rows has no field.
                    .onDelete(perform: group.takesRows && group.rows.count > 1
                              ? { sheet.removeRows(at: $0, from: group.category) } : nil)
                    if group.takesRows {
                        Button("Добави ред", systemImage: "plus") { sheet.addRow(to: group.category) }
                            .accessibilityLabel("Добави ред към \(group.category.label)")
                            .accessibilityInputLabels(A11y.spokenNames("Добави ред"))
                    }
                } header: {
                    SectionHeader(group.category.label)
                }
            }
            summary
        }
        .disabled(locked)
    }

    private var unit: String { "\(currencyCode) / дка" }

    private var currencyCode: String {
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        return code.isEmpty ? "—" : code
    }

    /// The name field where a row can have its own — plant protection,
    /// fertiliser, services — and wherever the last sheet named one.
    @ViewBuilder
    private func rowView(_ row: Binding<CropSheet.Row>, in group: CropSheet.Group) -> some View {
        let named = group.takesRows || group.rows.count > 1 || !row.wrappedValue.name.isEmpty
        let removable = group.takesRows && group.rows.count > 1
        VStack(alignment: .leading, spacing: 8) {
            if named {
                TextField("Какво", text: row.name, prompt: .fieldPrompt("Какво — по избор"), axis: .vertical)
                    .foregroundStyle(Palette.Field.text)
                    .accessibilityLabel("\(group.category.label), какво")
                    .accessibilityInputLabels(A11y.spokenNames("Какво"))
            }
            FieldRow(unit, spoken: spokenRate(row.wrappedValue, in: group)) {
                TextField("0", text: row.perDcaText, prompt: .fieldPrompt("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    // The swipe that removes a row is touch's. The row is two
                    // fields, not one element, so the delete it carries is not
                    // reliably where VoiceOver or Switch Control focus lands;
                    // the rate field, which every row has, carries it too.
                    .accessibilityActions {
                        if removable {
                            Button("Премахни реда") { sheet.removeRow(row.wrappedValue.id, from: group.category) }
                        }
                    }
            }
            notes(row.wrappedValue)
        }
    }

    /// «Препарати, Хербицид, евро на декар» — the category and the row, which
    /// the visible «EUR / дка» leaves to the section header.
    private func spokenRate(_ row: CropSheet.Row, in group: CropSheet.Group) -> String {
        A11y.sentence([group.category.label, row.name,
                       "\(CurrencyWords.name(currencyCode, afterNumber: false)) на декар"])
    }

    /// What the prefill knew: when the figure was entered, whether it was
    /// converted, and why a named row came back empty.
    @ViewBuilder
    private func notes(_ row: CropSheet.Row) -> some View {
        Group {
            if let last = row.lastEnteredOn {
                Text("Последно въведено на \(BgDate.rowDayEndingSentence(last))")
            }
            if let leva = row.convertedFromLeva {
                Text(OverheadFields.convertedNote(leva))
            }
            if row.lastWasTotal {
                Text("Тогава е въведена обща сума, а не на декар — попълнете сумата на декар.")
            }
            if let code = row.unconvertedCurrency {
                Text("Последната стойност е в \(code) и не е попълнена.")
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - What it comes to

    private var summary: some View {
        Section {
            ValueRow("Площ") { Text("\(Num.text(Self.double(crop.areaDca))) дка") }
            if let perDca = sheet.perDcaSum {
                ValueRow("Общо на декар") { Text(Self.money(perDca, currencyCode)) }
            }
            if let total = sheet.totalAmount(areaDca: crop.areaDca) {
                ValueRow("Общо") { Text(Self.money(total, currencyCode)) }
            }
        } header: {
            SectionHeader("\(crop.name) в стопанството")
        } footer: {
            SectionFooter("Всеки ред е на декар и се умножава по площта на културата. "
                          + "Сезонът се определя от датата.")
        }
    }

    static func money(_ value: Decimal, _ currency: String) -> String {
        Money.text(double(value), currency)
    }

    /// For display only; what is sent stays a `Decimal`.
    static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
