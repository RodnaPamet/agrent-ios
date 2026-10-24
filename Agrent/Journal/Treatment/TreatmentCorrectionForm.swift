import SwiftUI

/// «Коригирай», step one: the treatment as recorded, with the fields the
/// server can correct editable (agrent-ios #392, owner 2026-10-24).
///
/// In «Ново мероприятие»'s order, so each field is where it was typed. The
/// product, the dose and the parcels are shown, locked, with one line saying
/// so. The person needs to see they are correcting the right treatment, and
/// isn't offered a change the server would refuse. They unlock when the
/// server can correct them.
struct TreatmentCorrectionForm: View {
    @Binding var draft: TreatmentCorrection.Draft
    /// The dose as the journal row writes it, with the unit's symbol. The
    /// definition carries only the unit's id.
    let doseText: String?
    let doseSpoken: String?
    let onNext: () -> Void
    let onCancel: () -> Void

    private var problems: [TreatmentCorrection.Draft.Problem] { draft.problems() }

    var body: some View {
        PageForm {
            Section {
                ValueRow("Вид") { Text(draft.kind.label) }
                DatePicker("Дата", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
            }

            Section {
                ValueRow("Търговско наименование") { Text(draft.original.productName) }
                if let number = draft.original.pppRegistrationNo?.recorded {
                    ValueRow(value: { Text(number) }, label: {
                        Text("Рег. № по ЗЗР").accessibilityLabel("Регистрационен номер по ЗЗР")
                    })
                }
            } header: {
                SectionHeader(draft.kind.inputLabel)
            } footer: {
                SectionFooter(TreatmentCorrection.lockedNote(draft.kind))
            }

            if draft.spraying {
                Section(titled: "Вредител") {
                    TextField("Вредител", text: $draft.pestText,
                              prompt: .fieldPrompt(TreatmentFieldsView.pestExample), axis: .vertical)
                        .promptRoom(TreatmentFieldsView.pestExample)
                }
            }

            Section(titled: "Доза") {
                ValueRow("Количество") {
                    Text(doseText ?? "—").accessibilityLabel(doseSpoken ?? doseText ?? "не е записана")
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
                    let area = line.treatedAreaHa.map(Area.init(hectares:))
                    ValueRow(line.parcelName) {
                        Text(area?.text ?? Self.wholeParcel)
                            .accessibilityLabel(area?.spoken ?? Self.wholeParcel)
                    }
                }
            } header: {
                SectionHeader("Парцели")
            }

            Section {
                Text(problems.first?.text ?? Self.nextNote)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inlineTitle(TreatmentCorrectionFlow.title)
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

    /// A line with no treated area of its own: the parcel was treated whole.
    /// The definition doesn't carry the parcel's area, so it says so in words.
    static let wholeParcel = "Целият парцел"
    private static let nextNote = "На следващата стъпка проверете промените, преди да ги запазите."
}
