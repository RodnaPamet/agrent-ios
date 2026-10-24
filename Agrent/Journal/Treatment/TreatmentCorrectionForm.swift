import SwiftUI

/// «Коригирай», step one: the treatment as recorded, with the fields the
/// server can correct editable (agrent-ios #392, owner 2026-10-24).
///
/// In «Ново мероприятие»'s order, so each field is where it was typed, and
/// everything it recorded is correctable since agri-saas #2293. Two things
/// are kept as recorded:
/// - the parcel SET, which a correction can't change; each parcel's treated
///   area can;
/// - the kind, and a water rate, which the phone's form never recorded:
///   left out of the body, so the server keeps them.
struct TreatmentCorrectionForm: View {
    @Binding var draft: TreatmentCorrection.Draft
    let reference: OperationReferenceStore
    let onNext: () -> Void
    let onCancel: () -> Void

    private var problems: [TreatmentCorrection.Draft.Problem] { draft.problems() }
    private var units: [Unit] { reference.units.value ?? [] }

    private var suggestions: [InputItem] {
        TypedProduct.suggestions(for: draft.productText, spraying: draft.spraying,
                                 in: reference.items.value ?? [])
    }

    var body: some View {
        PageForm {
            Section {
                ValueRow("Вид") { Text(draft.kind.label) }
                DatePicker("Дата", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
            }

            Section {
                TextField("Търговско наименование", text: $draft.productText,
                          prompt: .fieldPrompt("Търговско наименование"))
                    .autocorrectionDisabled()
                // The farm's own products the typed text is part of — a tap
                // takes the stored name, as on «Ново мероприятие».
                ForEach(suggestions) { item in
                    Button(item.name) { draft.productText = item.name }
                        .accessibilityHint("Попълва това наименование")
                }
            } header: {
                SectionHeader(draft.kind.inputLabel)
            } footer: {
                SectionFooter("С корекция се избира продукт от каталога на стопанството.")
            }

            if draft.spraying {
                Section(titled: "Вредител") {
                    TextField("Вредител", text: $draft.pestText,
                              prompt: .fieldPrompt(TreatmentFieldsView.pestExample), axis: .vertical)
                        .promptRoom(TreatmentFieldsView.pestExample)
                }
            }

            Section(titled: "Доза") {
                FieldRow("Количество") {
                    TextField("0", text: $draft.doseText, prompt: .fieldPrompt("0"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                MenuPicker("Мерна единица", selection: $draft.doseUnit, value: draft.doseUnit.symbol ?? "—") {
                    ForEach(draft.unitOptions(units), id: \.self) { unit in
                        Text(unit.symbol ?? "—").tag(unit)
                    }
                }
            }

            if draft.spraying {
                Section {
                    TextField("Фенофаза/BBCH", text: $draft.phenophaseText,
                              prompt: .fieldPrompt(TreatmentFieldsView.phenophaseExample))
                        .accessibilityInputLabels(A11y.spokenNames("Фенофаза", "BBCH", "Growth stage"))
                } header: {
                    SectionHeader("Фенофаза/BBCH")
                } footer: {
                    SectionFooter(TreatmentFieldsView.phenophaseNote)
                }

                Section {
                    FieldRow("Карантинен срок", spoken: "Карантинен срок в дни") {
                        TextField("дни", text: $draft.quarantineText, prompt: .fieldPrompt("дни"))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    ValueRow("Най-ранна дата за прибиране") {
                        Text(draft.earliestHarvest.map(BgDate.full) ?? "—")
                            .accessibilityLabel(draft.earliestHarvest.map(BgDate.full) ?? "не е изчислена")
                    }
                } header: {
                    SectionHeader("Карантинен срок")
                } footer: {
                    SectionFooter(TreatmentFieldsView.harvestNote)
                }

                Section {
                    MenuPicker("Техника", selection: $draft.technique,
                               value: TreatmentCorrection.Draft.techniqueLabel(draft.technique)) {
                        ForEach(draft.techniqueOptions, id: \.self) { slug in
                            Text(TreatmentCorrection.Draft.techniqueLabel(slug)).tag(slug)
                        }
                    }
                }
            }

            Section {
                ForEach(draft.original.lines, id: \.parcelId) { line in
                    // Decares, as on «Ново мероприятие»'s parcel step.
                    FieldRow(line.parcelName, spoken: "Третирана площ на \(line.parcelName) в декари") {
                        TextField("дка", text: $draft.areaTexts[typed: line.parcelId],
                                  prompt: .fieldPrompt(TreatmentCorrection.wholeParcel))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                SectionHeader("Третирана площ, дка")
            } footer: {
                SectionFooter(TreatmentCorrection.parcelsNote)
            }

            Section {
                Text(problems.first?.text ?? Self.nextNote)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inlineTitle(TreatmentCorrectionFlow.title)
        // The typed name against the catalogue, again whenever either moves.
        .onChange(of: draft.productText) { _, _ in draft.resolve(in: reference.items.value) }
        .onChange(of: reference.items) { _, now in draft.resolve(in: now.value) }
        .onChange(of: reference.units) { _, now in draft.name(units: now.value ?? []) }
        .task { await reference.load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отказ", action: onCancel)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Напред", action: onNext)
                    .disabled(!problems.isEmpty)
                    // Why it is dimmed, where the dimmed button is: the
                    // reason itself is the last row of a long form.
                    .accessibilityHint(problems.first?.text ?? "")
                    .accessibilityInputLabels(A11y.Spoken.next)
            }
        }
    }

    private static let nextNote = "На следващата стъпка проверете промените, преди да ги запазите."
}
