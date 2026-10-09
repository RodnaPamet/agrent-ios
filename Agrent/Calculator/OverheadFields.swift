import SwiftUI

/// What became of one overhead line when the sheet was saved (#245). The
/// one-line form's three outcomes, per line: lines are separate costs, so one
/// can land while another is refused.
enum OverheadLineResult: Equatable {
    case saved
    /// The server answered no; the line does not exist and may be sent again.
    case refused(String)
    /// The answer was lost; the line may or may not exist. NOT sent again —
    /// the owner's rule for a cost (2026-09-25): look at the list first.
    case unknown(String)
}

/// The «Общи» fields of «Нов разход» (#245): salaries, credit,
/// amortisation and other, each yearly, each spread over the whole farm.
/// The rules are `OverheadSheet`'s; this draws them, a section per line.
struct OverheadFields: View {
    @Binding var sheet: OverheadSheet
    let results: [CostCategory: OverheadLineResult]
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
    }

    // MARK: - Заплати

    private var payrollSection: some View {
        Section {
            Picker("Заплати", selection: $sheet.payrollMode) {
                Text("Общо").tag(OverheadSheet.PayrollMode.total)
                Text("По хора").tag(OverheadSheet.PayrollMode.perPerson)
            }
            .pickerStyle(.segmented)
            .disabled(isLocked(.payroll))
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
            .disabled(isLocked(.payroll))
            notes(.payroll, sheet.payroll)
        } header: {
            SectionHeader(CostCategory.payroll.label)
        }
    }

    // MARK: - Амортизация

    private var depreciationSection: some View {
        Section {
            amountRow(\.depreciation, locked: isLocked(.depreciation))
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
                           !isLocked(.depreciation) {
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
            notes(.depreciation, sheet.depreciation)
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
            amountRow(line, locked: isLocked(category))
            extra()
            notes(category, sheet[keyPath: line])
        } header: {
            SectionHeader(category.label)
        }
    }

    private func amountRow(_ line: WritableKeyPath<OverheadSheet, OverheadSheet.Line>, locked: Bool) -> some View {
        FieldRow("Годишно") {
            TextField("0", text: $sheet[dynamicMember: line].amountText, prompt: .fieldPrompt("0"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
        .disabled(locked)
    }

    /// When the prefill was last entered, and what became of the line.
    @ViewBuilder
    private func notes(_ category: CostCategory, _ line: OverheadSheet.Line) -> some View {
        if let last = line.lastEnteredOn, results[category] == nil {
            Text("Последно въведено на \(BgDate.rowDay(last)).")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
        switch results[category] {
        case .saved:
            Label("Записано.", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(Palette.success)
        case .refused(let message):
            Text("\(message) Не е записано — поправете и запазете отново.")
                .font(.footnote)
                .foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown(let message):
            Text("\(message) Връзката прекъсна преди отговора: проверете списъка с разходи, "
                 + "преди да го въведете отново.")
                .font(.footnote)
                .foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    /// A line that landed, or whose answer was lost, is not edited or sent
    /// again from this sheet.
    private func isLocked(_ category: CostCategory) -> Bool {
        switch results[category] {
        case .saved, .unknown: true
        case .refused, nil: false
        }
    }
}
