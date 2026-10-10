import SwiftUI

struct NewEntryView: View {
    let store: JournalStore

    @Environment(\.dismiss) private var dismiss
    @State private var type: LogEntryType = .activity
    @State private var title = ""
    @State private var notes = ""
    @State private var occurredAt = Date()
    @State private var saving = false
    @State private var error: String?

    /// The blocks the entry is about (#254). Several may be chosen, as on
    /// the web's «Свържи земеделски блокове» (owner, 2026-10-10).
    @State private var chosenBlocks: [JournalFilter.Block]
    /// The farm's blocks to choose from, read as the PDF sheet reads them.
    @State private var locations = LocationsStore()

    /// `preselected` is the block the Дневник is filtered by, if any. An
    /// entry written from block X's diary is most likely about block X, and
    /// with the link it stays in the list it was written from. Unchosen, it
    /// would be saved and then vanish from that list.
    init(store: JournalStore, preselected: [JournalFilter.Block] = []) {
        self.store = store
        _chosenBlocks = State(initialValue: preselected)
    }

    /// The farm's blocks, with any chosen one kept even before the list
    /// arrives or if it no longer offers it. What is ticked is what is sent.
    private var blockChoices: [JournalFilter.Block] {
        let offered = JournalFilter.Block.options(from: locations.state.value ?? [])
        return chosenBlocks.filter { !offered.contains($0) } + offered
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    // `MenuPicker`, not a bare `Picker`: the system's menu
                    // picker drew «Дейност» as «Де…ст» here, at the default
                    // text size (#160).
                    MenuPicker("Тип", english: "Type", selection: $type, value: type.label) {
                        // `selectable`, never `allCases` — the latter now carries
                        // `.unknown`, whose raw value the server would reject.
                        ForEach(LogEntryType.selectable) { Text($0.label).tag($0) }
                    }
                    DatePicker("Дата", selection: $occurredAt, displayedComponents: .date)
                        // The date while its calendar is open, in a tint
                        // measured on the pill — see `Palette.DatePill` (#164).
                        .tint(Palette.DatePill.tint)
                }
                Section(titled: "Заглавие") {
                    // No font-size dance here. UIKit's text input does not
                    // focus-zoom, which is the entire class of bug that took
                    // five fixes on the web.
                    //
                    // `promptRoom`, so the example WRAPS: at AX5 it was cut
                    // to «напр. Трети…», which says nothing (#164).
                    TextField("Заглавие", text: $title,
                              prompt: .fieldPrompt(Self.titleExample), axis: .vertical)
                        .promptRoom(Self.titleExample)
                }
                blocksSection
                Section(titled: "Бележки") {
                    TextEditor(text: $notes).frame(minHeight: 140)
                }
                if let error {
                    Section {
                        // `Palette.error`, not `.red` — 5.42:1 against
                        // 3.55:1, and the app has one colour for a failure.
                        Text(error).foregroundStyle(Palette.error)
                    }
                }
            }
            .inlineTitle("Нов запис")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Създай") { Task { await save() } }
                        .accessibilityInputLabels(A11y.Spoken.create)
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(saving)
            .task { await locations.load() }
        }
    }

    /// «Блокове»: optional, any number. Left out entirely on a farm with no
    /// block to link and nothing already chosen.
    @ViewBuilder
    private var blocksSection: some View {
        let choices = blockChoices
        if case .failed(let message) = locations.state, choices.isEmpty {
            Section(titled: "Блокове") {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if case .loading = locations.state, choices.isEmpty {
            Section(titled: "Блокове") { ProgressView() }
        } else if !choices.isEmpty {
            Section {
                ForEach(choices) { block in
                    ChoiceRow(title: block.name, chosen: chosenBlocks.contains(block)) {
                        toggle(block)
                    }
                }
            } header: {
                SectionHeader("Блокове")
            } footer: {
                SectionFooter(Self.blocksNote)
            }
        }
    }

    private func toggle(_ block: JournalFilter.Block) {
        if let at = chosenBlocks.firstIndex(of: block) {
            chosenBlocks.remove(at: at)
        } else {
            chosenBlocks.append(block)
        }
    }

    private static let blocksNote =
        "По избор. Записът се показва и когато дневникът е филтриран по някой от тези блокове."

    private func save() async {
        saving = true
        error = nil
        do {
            try await store.create(CreateLogEntry(
                type: type,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                // `notes` is a rich-text HTML column on both ends; the app
                // was POSTing plain text, so a two-paragraph note read as
                // one run-on paragraph on the web. See RichText.
                notes: RichText.html(fromPlainText: notes),
                occurredAt: occurredAt,
                // In the order they were ticked; nil, and left out, for none.
                locationIds: chosenBlocks.isEmpty ? nil : chosenBlocks.map(\.id)
            ))
            dismiss()
        } catch {
            // Stay open on failure. Closing a form after a refused write is
            // exactly the defect filed against the web app as #921 — it reads
            // as success and the operator's work is gone.
            self.error = UserMessage.text(for: error)
        }
        saving = false
    }

    /// The title's prompt: an example, whole, at every text size.
    private static let titleExample = "напр. Третиране на южния блок"
}
