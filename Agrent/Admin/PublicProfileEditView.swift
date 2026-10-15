import SwiftUI

/// The five fields of the farm's public page, edited in a sheet that saves
/// (agrent-ios #323). `FarmProfileEditView`'s shape: «Отказ» asks before
/// throwing typed text away, «Запази» is live only once something changed,
/// and a swipe down is a leave like any other.
///
/// It saves only what changed (`FarmBrandChange`): an untouched field is
/// left out, so this save can't undo what another administrator wrote in a
/// different field since the page was opened. An emptied field is cleared.
struct PublicProfileEditView: View {
    let saved: FarmBrandDraft?
    let onSaved: @MainActor () async -> Void

    @State private var edited: FarmBrandDraft
    @State private var newCrop = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(saved: FarmBrandDraft?, onSaved: @escaping @MainActor () async -> Void) {
        self.saved = saved
        self.onSaved = onSaved
        _edited = State(initialValue: saved ?? FarmBrandDraft())
    }

    /// A crop typed into «Нова култура» and not added yet counts: it's text
    /// the person would lose.
    private var dirty: Bool {
        !FarmBrandChange.between(saved, and: edited).isEmpty
            || !newCrop.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var problems: [String] { FarmBrandLimits.problems(in: edited) }

    var body: some View {
        NavigationStack {
            PageForm {
                if failure != nil || !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { problem in
                            Text(problem).font(.footnote).foregroundStyle(Palette.error)
                        }
                        if let failure {
                            Text(failure).font(.footnote).foregroundStyle(Palette.error)
                        }
                    }
                }

                Section {
                    TextField("Име на стопанството", text: text(\.displayName),
                              prompt: .fieldPrompt("Име на стопанството"), axis: .vertical)
                } header: {
                    SectionHeader("Име")
                } footer: {
                    SectionFooter("Без име страницата не може да бъде публикувана.")
                }

                Section {
                    TextField("Кратко описание", text: text(\.tagline),
                              prompt: .fieldPrompt("Едно изречение за стопанството"), axis: .vertical)
                } header: {
                    SectionHeader("Кратко описание")
                }

                Section {
                    TextField("За стопанството", text: text(\.about),
                              prompt: .fieldPrompt("—"), axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    SectionHeader("За стопанството")
                }

                Section {
                    Picker("Област", selection: $edited.oblast) {
                        Text("Не е посочена").tag(String?.none)
                        ForEach(FarmBrandLimits.oblasts(keeping: saved?.oblast), id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    // Its own page, not a menu: 28 names, and a menu
                    // picker's UIKit-drawn value cuts a long one (#160).
                    .pickerStyle(.navigationLink)
                } header: {
                    SectionHeader("Област")
                }

                cropsEditor
            }
            .inlineTitle(PublicProfileView.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") {
                        if dirty { confirmingDiscard = true } else { dismiss() }
                    }
                    .disabled(saving)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Запази") { Task { await save() } }
                            .disabled(!dirty || !problems.isEmpty)
                            .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            .interactiveDismissDisabled(dirty || saving)
            .confirmationDialog("Отхвърляне на промените?", isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Отхвърли промените", role: .destructive) { dismiss() }
                    .accessibilityInputLabels(A11y.Spoken.discard)
                Button("Продължи редакцията", role: .cancel) {}
            } message: {
                Text("Направените промени няма да бъдат записани.")
            }
        }
    }

    private func text(_ field: WritableKeyPath<FarmBrandDraft, String?>) -> Binding<String> {
        Binding(get: { edited[keyPath: field] ?? "" }, set: { edited[keyPath: field] = $0 })
    }

    // MARK: - Crops

    /// A list, as on «Стопанство» (`FarmProfileEditView.cropsEditor`):
    /// the farmer's order, a comma in a row still splits it, and a swipe
    /// removes one.
    private var cropsEditor: some View {
        Section {
            ForEach(edited.crops.indices, id: \.self) { index in
                TextField("Култура", text: cropBinding(index), prompt: .fieldPrompt("—"))
            }
            .onDelete { edited.crops.remove(atOffsets: $0) }

            HStack {
                TextField("Нова култура", text: $newCrop, prompt: .fieldPrompt("Нова култура"))
                    .onSubmit(addCrop)
                Button("Добави", action: addCrop)
                    .buttonStyle(.borderless)
                    .disabled(newCrop.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityInputLabels(A11y.spokenNames("Добави", "Add"))
            }
        } header: {
            SectionHeader("Култури")
        } footer: {
            SectionFooter("Например „пшеница“, „слънчоглед“. Плъзнете наляво, за да премахнете.")
        }
    }

    /// Guarded: `onDelete` can remove a row while its field holds focus.
    private func cropBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { edited.crops.indices.contains(index) ? edited.crops[index] : "" },
            set: { if edited.crops.indices.contains(index) { edited.crops[index] = $0 } }
        )
    }

    private func addCrop() {
        let parts = newCrop.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        edited.crops.append(contentsOf: parts)
        newCrop = ""
    }

    // MARK: - Save

    private func save() async {
        addCrop()
        let change = FarmBrandChange.between(saved, and: edited)
        guard !change.isEmpty else { return dismiss() }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            try await FarmBrandAPI.save(change)
            await onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// The server's bounds on the five fields (`UpdateFarmBrandSchema`), checked
/// before the request so the person reads which field and by how much,
/// rather than the schema's 400.
enum FarmBrandLimits {
    static let displayName = 120
    static let tagline = 200
    static let about = 2000
    static let crops = 40
    static let crop = 80

    static func problems(in draft: FarmBrandDraft) -> [String] {
        var found: [String] = []
        func check(_ value: String?, _ limit: Int, _ name: String) {
            let count = value?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            if count > limit { found.append("\(name) е \(count) знака, а може да е най-много \(limit).") }
        }
        check(draft.displayName, displayName, "Името")
        check(draft.tagline, tagline, "Краткото описание")
        check(draft.about, about, "Текстът „За стопанството“")
        let crops = draft.crops.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if crops.count > Self.crops {
            found.append("Културите са \(crops.count), а може да са най-много \(Self.crops).")
        }
        if crops.contains(where: { $0.trimmingCharacters(in: .whitespaces).count > crop }) {
            found.append("Име на култура може да е най-много \(crop) знака.")
        }
        return found
    }

    /// The 28 oblasti by their Bulgarian names, the server's verbatim
    /// (`BulgarianRegion.names`), in Bulgarian order. The server keeps the
    /// brand's oblast as free text, and its own tests and search use those
    /// names («Добрич»). A saved value that isn't one of them (typed on the
    /// web, say) is kept at the top, so opening the editor doesn't change it.
    static func oblasts(keeping saved: String?) -> [String] {
        let names = Array(Set(BulgarianRegion.names.values))
            .sorted { $0.compare($1, locale: BgDate.locale) == .orderedAscending }
        guard let saved = saved?.recorded, !names.contains(saved) else { return names }
        return [saved] + names
    }
}
