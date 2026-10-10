import SwiftUI

/// The «Общи» fields of «Нов разход» (#245): salaries, credit,
/// amortisation and other, each yearly, each spread over the whole farm.
/// The rules are `OverheadSheet`'s; this draws them, a section per line.
struct OverheadFields: View {
    @Binding var sheet: OverheadSheet
    /// The sheet was sent and its answer lost (#260): it may be in the books,
    /// so nothing on it is edited or sent again from here — the owner's rule
    /// for a cost (2026-09-25): look at the list first.
    let locked: Bool
    /// The machine register's depreciation, once read — nil before, and when
    /// it could not be.
    let machinery: MachineryDepreciation?

    var body: some View {
        Group {
            payrollSection
            yearly(.credit, \.credit)
            depreciationSection
            yearly(.other, \.other) {
                TextField("Какво", text: $sheet.otherNote, prompt: .fieldPrompt("по избор"), axis: .vertical)
            }
        }
        .disabled(locked)
    }

    // MARK: - Заплати

    private var payrollSection: some View {
        Section {
            Picker("Заплати", selection: $sheet.payrollMode) {
                Text("Общо").tag(OverheadSheet.PayrollMode.total)
                Text("По хора").tag(OverheadSheet.PayrollMode.perPerson)
            }
            .pickerStyle(.segmented)
            .onChange(of: sheet.payrollMode) { sheet.peopleChanged() }

            if sheet.payrollMode == .perPerson {
                FieldRow("Брой хора") {
                    TextField("0", text: $sheet.headcountText, prompt: .fieldPrompt("0"))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: sheet.headcountText) { sheet.peopleChanged() }
                }
                FieldRow("Годишно на човек") {
                    TextField("0", text: $sheet.perPersonText, prompt: .fieldPrompt("0"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: sheet.perPersonText) { sheet.peopleChanged() }
                }
            }
            FieldRow(sheet.payrollMode == .perPerson ? "Общо за годината" : "Годишно") {
                TextField("0", text: Binding(
                    get: { sheet.payroll.amountText },
                    set: { typed in
                        // Typed over in per-person mode: the total is now
                        // the farmer's (a hire who started in May).
                        if typed != sheet.payroll.amountText, sheet.payrollMode == .perPerson {
                            sheet.payrollTotalEdited = true
                        }
                        sheet.payroll.amountText = typed
                    }), prompt: .fieldPrompt("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            notes(sheet.payroll)
        } header: {
            SectionHeader(CostCategory.payroll.label)
        }
    }

    // MARK: - Амортизация

    private var depreciationSection: some View {
        Section {
            amountRow(\.depreciation)
            if let machinery {
                // The register's figure beside the field, and what it leaves
                // out — the owner's «both»: offered, and typed over at will.
                if let offered = machinery.offered {
                    HStack(alignment: .firstTextBaseline) {
                        Text("По регистъра на техниката: \(OverheadSheet.fieldText(offered))")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if OverheadSheet.amount(sheet.depreciation.amountText) != offered,
                           !locked {
                            Button("Използвай") { sheet.useRegister(offered, onlyIfEmpty: false) }
                                .font(.footnote)
                        }
                    }
                }
                ForEach(machinery.caveats, id: \.self) { caveat in
                    Text(caveat)
                        .font(.footnote)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            notes(sheet.depreciation)
        } header: {
            SectionHeader(CostCategory.depreciation.label)
        }
    }

    // MARK: - The plain yearly lines

    private func yearly<Extra: View>(
        _ category: CostCategory, _ line: WritableKeyPath<OverheadSheet, OverheadSheet.Line>,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        Section {
            amountRow(line)
            extra()
            notes(sheet[keyPath: line])
        } header: {
            SectionHeader(category.label)
        }
    }

    private func amountRow(_ line: WritableKeyPath<OverheadSheet, OverheadSheet.Line>) -> some View {
        FieldRow("Годишно") {
            TextField("0", text: $sheet[dynamicMember: line].amountText, prompt: .fieldPrompt("0"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    /// «Превалутирано от 24 000,00 лв. по фиксирания курс 1,95583 лв. за 1 €.»
    nonisolated static func convertedNote(_ leva: Decimal) -> String {
        let figure = leva.formatted(.number.precision(.fractionLength(2)).grouping(.automatic).locale(BgDate.locale))
        return "Превалутирано от \(figure) лв. по фиксирания курс 1,95583 лв. за 1 €."
    }

    /// When the prefill was last entered, and whether it was converted from
    /// leva. What became of the save is the sheet's, said once below it:
    /// the lines land or fail together.
    @ViewBuilder
    private func notes(_ line: OverheadSheet.Line) -> some View {
        if let last = line.lastEnteredOn {
            Text("Последно въведено на \(BgDate.rowDay(last)).")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
        if let leva = line.convertedFromLeva {
            Text(Self.convertedNote(leva))
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
