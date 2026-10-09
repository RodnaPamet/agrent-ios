import SwiftUI

/// «Филтри» on the Дневник (#252): type, crop, block and period, chosen on a
/// draft and applied together by «Покажи».
///
/// A draft rather than a live filter, because each change is a request to the
/// server. Four choices made one after another would be four requests on a
/// field's connection, three of them for lists nobody wanted to see.
struct JournalFilterSheet: View {
    let options: JournalFilterOptions
    let apply: (JournalFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: JournalFilter

    init(filter: JournalFilter, options: JournalFilterOptions,
         apply: @escaping (JournalFilter) -> Void) {
        self.options = options
        self.apply = apply
        _draft = State(initialValue: filter)
    }

    private static let all = "Всички"

    private static let cropNote =
        "По култура се показват записите от операции върху парцели с тази култура."
    private static let blockNote =
        "По блок се показват записите, свързани с блока, и операциите върху парцелите му."

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    MenuPicker("Тип", english: "Type", selection: $draft.type,
                               value: draft.type?.label ?? Self.all) {
                        Text(Self.all).tag(LogEntryType?.none)
                        // `selectable`, never `allCases`: `.unknown` is a
                        // value the server would refuse.
                        ForEach(LogEntryType.selectable) { Text($0.label).tag(LogEntryType?.some($0)) }
                    }
                }

                Section {
                    cropRow
                } footer: {
                    SectionFooter(cropFooter)
                }

                Section {
                    blockRow
                } footer: {
                    SectionFooter(Self.blockNote)
                }

                Section {
                    MenuPicker("Период", english: "Period", selection: $draft.period,
                               value: draft.period.label) {
                        ForEach(JournalFilter.Period.allCases) { Text($0.label).tag($0) }
                    }
                    if draft.period == .custom {
                        DatePicker("От", selection: $draft.customFrom, in: ...draft.customTo,
                                   displayedComponents: .date)
                            .tint(Palette.DatePill.tint)
                        DatePicker("До", selection: $draft.customTo, in: draft.customFrom...,
                                   displayedComponents: .date)
                            .tint(Palette.DatePill.tint)
                    }
                }

                if draft.isActive {
                    Section {
                        Button("Изчисти филтрите") { draft = JournalFilter() }
                    }
                }
            }
            .inlineTitle("Филтри")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Покажи") {
                        apply(draft)
                        dismiss()
                    }
                    .accessibilityInputLabels(A11y.Spoken.show)
                }
            }
            .task { await options.load() }
        }
    }

    // MARK: - Crop

    @ViewBuilder
    private var cropRow: some View {
        if let crops = options.crops {
            if crops.isEmpty, draft.crop == nil {
                ValueRow("Култура") { Text(cropsMissing) }
            } else {
                MenuPicker("Култура", english: "Crop", selection: $draft.crop,
                           value: draft.crop?.label ?? Self.all) {
                    Text(Self.all).tag(JournalFilter.Crop?.none)
                    ForEach(Self.keeping(draft.crop, in: crops), id: \.self) {
                        Text($0.label).tag(JournalFilter.Crop?.some($0))
                    }
                }
            }
        } else {
            // A failed list of blocks is said once, under «Блок»; here the
            // crops simply have nothing to come from.
            ValueRow("Култура") { ProgressView() }
        }
    }

    private var cropsMissing: String {
        if case .failed = options.blocks { return "—" }
        return "Няма записани"
    }

    private var cropFooter: String {
        options.cropsIncomplete
            ? Self.cropNote + " Парцелите на някои блокове не се заредиха, затова може да липсва култура."
            : Self.cropNote
    }

    // MARK: - Block

    @ViewBuilder
    private var blockRow: some View {
        switch options.blocks {
        case .loading:
            ValueRow("Блок") { ProgressView() }
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let blocks, _) where blocks.isEmpty && draft.block == nil:
            ValueRow("Блок") { Text("Няма блокове") }
        case .loaded(let blocks, _):
            MenuPicker("Блок", english: "Block", selection: $draft.block,
                       value: draft.block?.name ?? Self.all) {
                Text(Self.all).tag(JournalFilter.Block?.none)
                ForEach(Self.keeping(draft.block, in: blocks)) {
                    Text($0.name).tag(JournalFilter.Block?.some($0))
                }
            }
        }
    }

    /// The options, with the current choice kept even when the farm no longer
    /// offers it. A picker whose selection matches no tag shows nothing
    /// chosen, while the filter goes on applying it.
    nonisolated static func keeping<T: Equatable>(_ chosen: T?, in options: [T]) -> [T] {
        guard let chosen, !options.contains(chosen) else { return options }
        return [chosen] + options
    }
}
