import SwiftUI

/// «Коригирай», step one, on an activity: what it was, its day, a harvest's
/// total, and its parcels with each one's area (#447). The kind stays as
/// recorded, and the form says so rather than showing a field that can't
/// move.
///
/// The parcels as a treatment's correction lists them, block by block, the
/// recorded ones ticked; and then any other of the farm's blocks, chosen from
/// «Друг блок» (owner, 2026-10-26). A treatment can't take one, as the БАБХ
/// register prints a table per block; an activity isn't in that register.
struct ActivityCorrectionForm: View {
    @Binding var draft: ActivityCorrection.Draft
    let blocks: TreatmentBlocks
    let onNext: () -> Void
    let onCancel: () -> Void

    /// The block chosen from «Друг блок», read by the task it keys.
    @State private var addedBlock: String?

    private var problems: [ActivityCorrection.Draft.Problem] { draft.problems() }

    var body: some View {
        PageForm {
            Section {
                ValueRow("Вид") { Text(draft.activity?.label ?? "—") }
                DatePicker("Дата", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
            } footer: {
                SectionFooter(Self.keptNote)
            }

            if draft.isHarvest {
                Section {
                    FieldRow("Количество", spoken: "Прибрано количество в килограми") {
                        TextField("кг", text: $draft.harvestText, prompt: .fieldPrompt("кг"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    SectionHeader("Прибрано, кг")
                } footer: {
                    SectionFooter(Self.harvestNote)
                }
            }

            ForEach(blockSections, id: \.id) { block in
                Section {
                    ForEach(block.parcels) { parcel in parcelRow(parcel) }
                } header: {
                    SectionHeader(block.name)
                }
            }

            if !otherBlocks.isEmpty || blocks.adding != nil {
                Section {
                    if blocks.adding != nil {
                        ProgressView()
                            .accessibilityLabel("Зареждане на блока")
                            .frame(maxWidth: .infinity)
                    } else {
                        Menu {
                            ForEach(otherBlocks) { block in
                                Button(block.name) { addedBlock = block.id }
                            }
                        } label: {
                            Label(Self.otherBlockTitle, systemImage: "plus")
                        }
                        .accessibilityInputLabels(A11y.spokenNames(Self.otherBlockTitle, "Друг блок", "Another block"))
                    }
                } footer: {
                    SectionFooter(Self.otherBlockNote)
                }
            }

            if !draft.chosenParcels.isEmpty {
                Section {
                    ForEach(draft.chosenParcels) { parcel in
                        // Decares, as on «Нов запис»'s parcel step, the
                        // parcel's own area as the prompt where it's known.
                        let own = parcel.areaHa.map(Area.init(hectares:))
                        FieldRow(parcel.name, spoken: "Площ на \(parcel.name) в декари") {
                            TextField("дка", text: $draft.areaTexts[typed: parcel.id],
                                      prompt: .fieldPrompt(own?.number ?? TreatmentCorrection.wholeParcel))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    SectionHeader("Площ, дка")
                } footer: {
                    SectionFooter(TreatmentCorrection.areasNote)
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
        // Keyed by the block chosen: a second choice while one is read waits
        // for `add`'s own guard, and leaving the form cancels the read.
        .task(id: addedBlock) {
            guard let id = addedBlock else { return }
            await blocks.add(blockID: id)
            draft.offer(blocks.blocks)
            addedBlock = nil
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отказ", action: onCancel)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Напред", action: onNext)
                    .disabled(!problems.isEmpty)
                    .accessibilityHint(problems.first?.text ?? "")
                    .accessibilityInputLabels(A11y.Spoken.next)
            }
        }
    }

    /// The parcels by block: the recorded blocks first, then those added,
    /// each headed by the block's name.
    private var blockSections: [(id: String, name: String, parcels: [TreatmentCorrection.Draft.ParcelChoice])] {
        var seen = Set<String>()
        let ids = draft.parcels.map(\.blockID).filter { seen.insert($0).inserted }
        return ids.map { id in
            let name = blocks.blocks.first { $0.id == id }?.name?.recorded
                ?? blocks.farmBlocks.first { $0.id == id }?.name.recorded ?? "Блок"
            return (id, name, draft.parcels.filter { $0.blockID == id })
        }
    }

    /// The farm's blocks not listed yet, by name.
    private var otherBlocks: [Location] {
        let listed = Set(draft.parcels.map(\.blockID))
        return blocks.farmBlocks
            .filter { !listed.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One parcel, ticked when the correction keeps or adds it.
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

    /// What isn't corrected here, and where it is: another kind is another
    /// record.
    static let keptNote = "Видът остава както е записан. "
        + "Друг вид работа се записва като нов запис, а грешен запис се изтрива от Дневник."
    /// «Нов запис»'s note, for parcels already recorded rather than chosen.
    static let harvestNote = "Общото прибрано количество от всички парцели на записа."
    static let otherBlockTitle = "Добави парцели от друг блок"
    static let otherBlockNote = "Парцелите на избрания блок се добавят в списъка неотметнати."
    /// The blocks' parcels couldn't be read: the recorded ones stay
    /// correctable.
    static let blocksFailed = "Някои блокове не можаха да се заредят. "
        + "Записаните парцели могат да се коригират; опитайте отново, за да добавите други."
    private static let nextNote = "На следващата стъпка проверете промените, преди да ги запазите."
}
