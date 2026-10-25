import SwiftUI

/// «Коригирай», step one: the treatment as recorded, with the fields the
/// server can correct editable (agrent-ios #392, owner 2026-10-24).
///
/// In «Ново мероприятие»'s order, so each field is where it was typed, and
/// everything it recorded is correctable (agri-saas #2293, #2304). The
/// parcels are its parcel step folded in: a ticked list per block, then each
/// ticked parcel's treated area. Only the treatment's own blocks are listed,
/// as a correction can't add another. Kept as recorded: the kind, and a
/// water rate, which the phone's form never records.
struct TreatmentCorrectionForm: View {
    @Binding var draft: TreatmentCorrection.Draft
    let reference: OperationReferenceStore
    let blocks: TreatmentBlocks
    let onNext: () -> Void
    let onCancel: () -> Void

    private var problems: [TreatmentCorrection.Draft.Problem] { draft.problems() }
    private var units: [Unit] { reference.units.value ?? [] }

    private var suggestions: [InputItem] {
        TypedProduct.suggestions(for: draft.productText, use: draft.kind.use,
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
                TextField(draft.kind.productField, text: $draft.productText,
                          prompt: .fieldPrompt(draft.kind.productField))
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

            Section(titled: draft.kind.doseWord) {
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

            ForEach(blockSections, id: \.id) { block in
                Section {
                    ForEach(block.parcels) { parcel in parcelRow(parcel) }
                } header: {
                    SectionHeader(block.name)
                }
            }

            if !draft.chosenParcels.isEmpty {
                Section {
                    ForEach(draft.chosenParcels) { parcel in
                        // Decares, as on «Ново мероприятие»'s parcel step, the
                        // parcel's own area as the prompt where it's known.
                        let own = parcel.areaHa.map(Area.init(hectares:))
                        FieldRow(parcel.name, spoken: "Третирана площ на \(parcel.name) в декари") {
                            TextField("дка", text: $draft.areaTexts[typed: parcel.id],
                                      prompt: .fieldPrompt(own?.number ?? TreatmentCorrection.wholeParcel))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    SectionHeader("Третирана площ, дка")
                } footer: {
                    SectionFooter("\(TreatmentCorrection.areasNote) \(TreatmentCorrection.parcelsNote)")
                }
            }

            if blocks.failed {
                Section {
                    Text(Self.blocksFailed)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// The parcels by block, in the order the treatment names its blocks,
    /// each headed by the block's name.
    private var blockSections: [(id: String, name: String, parcels: [TreatmentCorrection.Draft.ParcelChoice])] {
        draft.blockIDs.map { id in
            let name = blocks.blocks.first { $0.id == id }?.name?.recorded ?? "Блок"
            return (id, name, draft.parcels.filter { $0.blockID == id })
        }
    }

    /// One parcel, ticked when the correction keeps or adds it: the parcel
    /// step's row, one tap to change.
    private func parcelRow(_ parcel: TreatmentCorrection.Draft.ParcelChoice) -> some View {
        let picked = draft.chosen.contains(parcel.id)
        let area = parcel.areaHa.map(Area.init(hectares:))
        return Button {
            if picked { draft.chosen.remove(parcel.id) } else { draft.chosen.insert(parcel.id) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parcel.name)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let area {
                        Text(area.text)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if picked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(A11y.sentence([parcel.name, area?.spoken]))
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityInputLabels([parcel.name])
    }

    private static let nextNote = "На следващата стъпка проверете промените, преди да ги запазите."
    /// The blocks' parcels couldn't be read: the recorded ones are still
    /// listed and correctable, and nothing can be added until they are.
    static let blocksFailed = "Другите парцели на блоковете не можаха да се заредят. "
        + "Записаните парцели могат да се коригират; за да добавите парцел, отворете корекцията отново."
}
