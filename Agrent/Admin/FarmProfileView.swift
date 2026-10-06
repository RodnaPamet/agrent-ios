import SwiftUI

/// «Профил на стопанството» — the БАБХ identity block, shown and edited.
///
/// ── PORTED FROM THE AGREED WEB/SERVER PLAN ──
///
/// Read-only on iOS until 2026-10-01. The plan for writing it was agreed with
/// the agri-saas backend and already shipped there: agri-saas#1141 built the
/// web editor and the usecase, #1145 documented `PUT /admin/farm-profile`.
/// This page ports that — the web page
/// (`src/app/t/[tenantSlug]/(app)/admin/farm-profile/page.tsx`) is the
/// specification for fields, order, labels, hints and save behaviour, and
/// the route's zod schema for limits. The rules that make the write safe are
/// in `FarmProfileEditing.swift`.
///
/// ONE CARD, as the web has: «Идентификация на стопанството», thirteen
/// fields in the web's order, the web's paragraph under it. A producer /
/// holding split was considered and not made — it would be an iOS invention
/// over a page the web keeps whole.
///
/// What is iOS-only, and why:
///   - the ЕГН is masked with an explicit reveal, in view AND in edit (#110);
///   - the page covers itself in the app switcher (`privacyCover`);
///   - the size shows its decare equivalent, because every other area in
///     this app is in decares;
///   - an unparseable size is refused instead of sent as null (which clears);
///   - after a save, anything the server changed is SAID, not just shown.
struct FarmProfileView: View {
    let store: AdminStore
    @State private var revealEGN = false
    @State private var editing = false

    var body: some View {
        content
            .inlineTitle("Профил на стопанството")
            .toolbar {
                // ONLY FOR A READER THE SERVER WOULD TAKE A WRITE FROM. GET and
                // PUT share `admin.manage`, so `canEditProfile` is "the GET
                // succeeded" — and never true over the all-null stand-in a 403
                // produces, which an editor would write back as thirteen nulls.
                if store.canEditProfile, store.profile.value != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Редактирай") { editing = true }
                            .accessibilityInputLabels(A11y.Spoken.edit)
                    }
                }
            }
            .sheet(isPresented: $editing) {
                if let original = store.profile.value {
                    FarmProfileEditView(
                        original: original,
                        save: { body, draft in try await store.saveProfile(body, typed: draft) },
                        reload: { try await store.reloadProfile() })
                }
            }
            .writeFeedback(store.profileSaveFeedback)
            .privacyCover()
            // The «записан» note describes ONE save. Leaving and coming back is
            // a fresh look at the profile, and a note still sitting there would
            // describe a save the farmer has moved on from.
            .onDisappear { store.clearSaveNotes() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if let notes = store.lastSaveNotes {
                Section { savedNotice(notes) }.pageRow()
            }
            profileSection.pageRow()
        }
        .refreshable { await PullToRefresh.bounded { await store.load() } }
        .pageBackground()
    }

    @ViewBuilder
    private func savedNotice(_ notes: [String]) -> some View {
        Label(FarmProfileSaveReport.saved, systemImage: "checkmark.circle")
            .foregroundStyle(Palette.success)
        if !notes.isEmpty {
            // What the SERVER stored differs from what was typed. The rows
            // below already show the stored values — this says which ones
            // moved, because a dropped duplicate otherwise just vanishes.
            Text("Сървърът промени част от данните:")
                .font(.footnote).foregroundStyle(Palette.secondaryText)
            ForEach(notes, id: \.self) { note in
                Text(note).font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let heading = "Идентификация на стопанството"

    /// The web's paragraph under the card heading, verbatim.
    static let about = "Данните се отпечатват в „ДНЕВНИК за проведените растителнозащитни "
        + "мероприятия и торене“ (Приложение 1 към заповед № РД 11-3194/31.12.2021 г. "
        + "на БАБХ). Всички полета са незадължителни — празните остават като точки във формата."

    @ViewBuilder
    private var profileSection: some View {
        switch store.profile {
        case .loading:
            Section(Self.heading) { ProgressView() }

        case .failed(let message):
            Section(Self.heading) {
                ErrorState(message: message) { await store.load() }
            }

        case .loaded(let profile, _) where profile.isEmpty:
            // AN ORDINARY STATE, NOT AN ERROR. The server answers an unset
            // profile with all nulls and `[]`, never a 404 — so this is a farm
            // that has not filled the form in yet, and the useful thing is the
            // way to fill it.
            Section {
                Text("Данните за стопанството още не са попълнени.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                if store.canEditProfile {
                    Button("Попълни") { editing = true }
                }
            } header: {
                Text(Self.heading)
            } footer: {
                Text(Self.about)
            }

        case .loaded(let profile, _):
            Section {
                ForEach(FarmProfileText.allCases, id: \.self) { field in
                    if field == .egn {
                        egnField(profile.egn)
                    } else {
                        self.field(field.label, profile[keyPath: field.wire])
                    }
                }
                sizeField(profile.sizeHa)
                grainField(profile.grainProduced)
            } header: {
                Text(Self.heading)
            } footer: {
                Text(Self.about)
            }
        }
    }

    /// An EGN is a national identity number, and this is the one field where
    /// the mobile context genuinely differs from the web's.
    ///
    /// The web renders it plainly, which is right on a laptop. A phone is
    /// read over shoulders in a co-op office or a queue, so it is masked
    /// with an explicit reveal — still shown, still one tap, and not sitting
    /// on screen for anyone standing behind the operator.
    ///
    /// Masked by DIGIT COUNT, not by a fixed run of dots: showing the wrong
    /// length would make a wrong value look plausible when revealed.
    @ViewBuilder
    private func egnField(_ egn: String?) -> some View {
        if let egn, !egn.isEmpty {
            EGNRow(egn: egn, reveal: $revealEGN)
        }
    }

    /// Declared hectares, and NOTHING when it was never declared.
    ///
    /// A DECLARED ZERO IS SHOWN. `field` hides an empty string because an
    /// absent name is nothing to say; a zero here is something the farm told
    /// the state, and hiding it would make "declared nothing" and "declared
    /// nothing yet" the same row. So this branches on nil, not on falsity.
    ///
    /// HECTARES FIRST, under the web's label «(ха)», because that is the
    /// figure the farm declared and the one the editor takes. The decares
    /// follow because every other area in this app is in decares
    /// (`Area`), and a farmer comparing this with Локации should not have to
    /// carry a ×10.
    @ViewBuilder
    private func sizeField(_ hectares: Double?) -> some View {
        if let hectares {
            let area = Area(hectares: hectares)
            VStack(alignment: .leading, spacing: 3) {
                Text("Размер на стопанството (ха)")
                    .font(.footnote).foregroundStyle(Palette.secondaryText)
                Text("\(FarmProfileDraft.hectaresText(hectares)) ха (\(area.text))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            // «ха» and «дка» are read letter by letter; the spoken form says
            // the units.
            .accessibilityLabel("Размер на стопанството, "
                + "\(FarmProfileDraft.hectaresText(hectares)) хектара, \(area.spoken)")
        }
    }

    /// The declared crops, through `CommodityName`.
    ///
    /// FREE VALUES, not slugs. The web stores what the farmer typed —
    /// «пшеница, слънчоглед» — and #1141 chose an array of free strings over
    /// the commodity enum on purpose: a farm may grow something the market
    /// does not quote. Older rows and fixtures hold slugs (`wheat`), so
    /// `freeText` translates a canonical name when it happens to be one and
    /// otherwise shows the value EXACTLY as written. Order is the farmer's.
    @ViewBuilder
    private func grainField(_ crops: [String]) -> some View {
        if !crops.isEmpty {
            field("Произвеждани култури",
                  crops.map { CommodityName.freeText($0) ?? $0 }.joined(separator: ", "))
        }
    }

    /// Label ABOVE the value, not beside it. The web's labels are long —
    /// «Място на регистриране (местоположение на стопанството)» — and a
    /// `LabeledContent` squeezed that and an address into one line's width.
    @ViewBuilder
    private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.footnote).foregroundStyle(Palette.secondaryText)
                Text(value).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The masked ЕГН, shared by the profile page and the editor so the two
/// cannot disagree about what is spoken.
///
/// Moved unchanged from `AdminView`, accessibility treatment included.
private struct EGNRow: View {
    let egn: String
    @Binding var reveal: Bool

    var body: some View {
        LabeledContent("ЕГН") {
            HStack(spacing: 10) {
                Text(reveal ? egn : String(repeating: "•", count: egn.count))
                    .font(.body.monospacedDigit())
                Button(reveal ? "Скрий" : "Покажи") { reveal.toggle() }
                    .font(.footnote)
            }
        }
        // The number itself is never in the label. VoiceOver reads
        // aloud, and a national ID spoken in a shared space is the
        // same exposure this masking exists to avoid.
        //
        // ── AND `children: .ignore` SWALLOWED THE ONLY CONTROL ──
        //
        // Collapsing the row to one element discarded the «Покажи»
        // Button with everything else, so the hint promised a double tap
        // that did nothing: the element carried no action. The ЕГН could
        // not be revealed by VoiceOver at all, the button was absent from
        // the Switch Control and Full Keyboard focus order, and Voice
        // Control had no element named «Покажи» to act on. Reachable only
        // by a finger on the exact glyphs.
        //
        // Found by two independent lenses of an accessibility audit, which
        // is the corroboration that made it worth trusting: the privacy
        // instinct was right and the side effect was invisible from
        // either one alone.
        //
        // The action restores it without putting the digits back into
        // speech — the label still says only whether it is shown.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reveal ? "ЕГН, показано" : "ЕГН, скрито")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { reveal.toggle() }
        // What a Voice Control user SEES on the button, so «Покажи» works
        // as spoken. The visible word is not in the accessibility label
        // and would otherwise match nothing.
        .accessibilityInputLabels(reveal
            ? A11y.spokenNames("Скрий", "ЕГН", "Hide")
            : A11y.spokenNames("Покажи", "ЕГН", "Show"))
        .accessibilityHint(reveal ? "Скрива номера" : "Показва номера")
    }
}

// MARK: - Edit

/// The editor: one form, Отказ / Запази, the house sheet shape.
///
/// SAVE IS READ-MODIFY-WRITE OF THE WHOLE OBJECT. The draft starts from the
/// loaded profile; `FarmProfileUpdate.build` sends every untouched field back
/// exactly as loaded and clears only a field the farmer emptied. Never a
/// per-field PUT — correct whether or not the server merges (agri-saas#1181).
///
/// THE OPTIMISTIC LOCK (agri-saas#1184): the save carries the version this
/// sheet opened on. A 409 stops the sheet — nothing typed is lost and nothing
/// is retried — until the farmer reloads; see `FarmProfileRebase`.
struct FarmProfileEditView: View {
    let save: (FarmProfileUpdate, FarmProfileDraft) async throws -> Void
    let reload: () async throws -> FarmProfile

    @Environment(\.dismiss) private var dismiss
    @State private var draft: FarmProfileDraft
    @State private var newCrop = ""
    @State private var revealEGN = false
    @State private var saving = false
    @State private var problems: [FarmProfileUpdate.Problem] = []
    @State private var failure: String?
    @State private var confirmingDiscard = false

    /// A refused save — the 409 included — played here because a refused
    /// editor stays open. The success is played by the page underneath,
    /// from `AdminStore.profileSaveFeedback`. A form problem caught before
    /// sending is not a write and plays nothing. See `WriteFeedback`.
    @State private var feedback = WriteFeedback()

    /// The profile the draft is an edit OF — and so the version the save
    /// sends. State, not a `let`: a reload after a 409 moves it to what is
    /// stored now, and every "untouched" judgement moves with it.
    @State private var original: FarmProfile
    /// A 409 landed and has not been reloaded over. While true, «Запази» is
    /// off: the same body with the same version can only 409 again, and a
    /// save without the version would be the silent overwrite.
    @State private var conflicted = false
    @State private var reloading = false
    /// Said once, after a reload: the fields both people changed.
    @State private var reloadNotes: [String]?

    init(original: FarmProfile,
         save: @escaping (FarmProfileUpdate, FarmProfileDraft) async throws -> Void,
         reload: @escaping () async throws -> FarmProfile) {
        self.save = save
        self.reload = reload
        _original = State(initialValue: original)
        _draft = State(initialValue: FarmProfileDraft(original))
    }

    /// Changed from what was loaded. A crop typed into «Нова култура» and
    /// not yet added counts: it is text the farmer would lose.
    private var dirty: Bool {
        draft != FarmProfileDraft(original)
            || !newCrop.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if conflicted {
                    conflictSection
                } else if let reloadNotes {
                    Section {
                        Text(FarmProfileConflict.reloaded).font(.footnote)
                        ForEach(reloadNotes, id: \.self) { note in
                            Text(note).font(.footnote).foregroundStyle(Palette.warning)
                        }
                    }
                }
                if failure != nil || !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.message) { problem in
                            Text(problem.message).font(.footnote).foregroundStyle(Palette.error)
                        }
                        if let failure {
                            Text(failure).font(.footnote).foregroundStyle(Palette.error)
                            // TRUE OF THIS WRITE, unlike the member writes. A
                            // whole-object PUT stores the same row however many
                            // times it lands, so «Запази» again is safe. NOT
                            // said over a 409 whose reload failed: there
                            // «Запази» is off and the way on is «Презареди».
                            if !conflicted {
                                Text("Записът може да се повтори безопасно — повторното "
                                     + "изпращане записва същите данни.")
                                    .font(.footnote).foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                }

                Section {
                    ForEach(FarmProfileText.allCases, id: \.self) { field in
                        if field == .egn {
                            egnEditor
                        } else {
                            textEditor(field)
                        }
                    }
                    sizeEditor
                } header: {
                    Text(FarmProfileView.heading)
                } footer: {
                    Text(FarmProfileView.about)
                }

                cropsEditor
            }
            .inlineTitle("Профил на стопанството")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") {
                        if dirty { confirmingDiscard = true } else { dismiss() }
                    }
                    .disabled(saving || reloading)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Запази") { Task { await submit() } }
                            // Not live until something changed: saving an
                            // untouched profile is a write (and an audit row)
                            // that says nothing. Nor over an unreloaded 409.
                            .disabled(!dirty || conflicted || reloading)
                            .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            // THE UNSAVED-CHANGES GUARD. A swipe down is the same «leave» as
            // Отказ and must ask the same question; while saving, nothing
            // leaves, so a write in flight is never orphaned by a gesture.
            .interactiveDismissDisabled(dirty || saving || reloading)
            .confirmationDialog("Отхвърляне на промените?",
                                isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Отхвърли промените", role: .destructive) { dismiss() }
                    .accessibilityInputLabels(A11y.Spoken.discard)
                Button("Продължи редакцията", role: .cancel) {}
            } message: {
                Text("Направените промени няма да бъдат записани.")
            }
            .writeFeedback(feedback)
            .privacyCover()
        }
    }

    // MARK: Fields

    private func binding(_ field: FarmProfileText) -> Binding<String> {
        Binding(get: { draft[field] }, set: { draft[field] = $0 })
    }

    /// Identifiers and codes: no autocorrection, no capitalisation.
    ///
    /// Autocorrection is not only a nuisance on «203912345». The keyboard
    /// LEARNS what is typed into a field that allows it, and offers it back
    /// as a suggestion elsewhere — a state identifier has no business in the
    /// predictive dictionary.
    private static let identifiers: Set<FarmProfileText> = [.egn, .eik, .urn, .registrationEkatte]

    @ViewBuilder
    private func textEditor(_ field: FarmProfileText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.footnote).foregroundStyle(Palette.secondaryText)
                // The field below carries the same words as its own label;
                // read once, not twice.
                .accessibilityHidden(true)
            TextField(field.label, text: binding(field), prompt: Text("—"), axis: .vertical)
                .autocorrectionDisabled(Self.identifiers.contains(field))
                .textInputAutocapitalization(Self.identifiers.contains(field) ? .never : .sentences)
            if let hint = field.hint {
                Text(hint).font(.caption).foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The ЕГН stays masked here too until the farmer reveals it.
    ///
    /// NOT a `SecureField`, which looks like the obvious tool and is a trap:
    /// a secure field CLEARS ITS WHOLE CONTENTS on the first keystroke after
    /// it regains focus. One stray tap and a character would replace a stored
    /// ЕГН. So: the masked row with «Покажи», and the plain field only after
    /// an explicit reveal — the same one tap as on the profile page.
    ///
    /// A blank ЕГН needs no mask (there is nothing to hide), so the field is
    /// offered straight away for a farm filling it in for the first time.
    @ViewBuilder
    private var egnEditor: some View {
        let current = draft[.egn]
        if current.isEmpty || revealEGN {
            VStack(alignment: .leading, spacing: 4) {
                Text(FarmProfileText.egn.label)
                    .font(.footnote).foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
                HStack {
                    TextField(FarmProfileText.egn.label, text: binding(.egn), prompt: Text("—"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospacedDigit())
                    if revealEGN {
                        Button("Скрий") { revealEGN = false }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                            .accessibilityInputLabels(A11y.spokenNames("Скрий", "ЕГН", "Hide"))
                    }
                }
                if let hint = FarmProfileText.egn.hint {
                    Text(hint).font(.caption).foregroundStyle(Palette.secondaryText)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                EGNRow(egn: current, reveal: $revealEGN)
                // The web's «Съхранява се криптирано.» on all three encrypted
                // fields, the masked state included.
                if let hint = FarmProfileText.egn.hint {
                    Text(hint).font(.caption).foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }

    /// The web's size input: TEXT with a decimal keypad, comma or dot.
    ///
    /// HECTARES, under the web's label, because that is the declared figure
    /// and the web, the server and the БАБХ form all speak it. Every other
    /// area in this app is in decares, so the decare equivalent is shown
    /// live under the field rather than converted silently either way.
    @ViewBuilder
    private var sizeEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Размер на стопанството (ха)")
                .font(.footnote).foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            TextField("Размер на стопанството в хектари", text: $draft.sizeHa, prompt: Text("—"))
                .keyboardType(.decimalPad)
            switch FarmProfileDraft.parseHectares(draft.sizeHa) {
            case .value(let ha):
                Text("= \(Area(hectares: ha).text)")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
                    .accessibilityLabel("Равно на \(Area(hectares: ha).spoken)")
            case .notANumber:
                Text("Въведете число, напр. 41,25.")
                    .font(.caption).foregroundStyle(Palette.error)
            case .negative:
                Text("Размерът не може да е отрицателен.")
                    .font(.caption).foregroundStyle(Palette.error)
            case .tooLarge:
                Text("Над 1 000 000 ха — проверете мерната единица.")
                    .font(.caption).foregroundStyle(Palette.error)
            case .blank:
                EmptyView()
            }
            Text("Както е декларирано. Може да се различава от сбора на картираните парцели.")
                .font(.caption).foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «Произвеждани култури» — the web's one comma-separated box, as a list.
    ///
    /// Same data, same rules: the web splits on commas, trims and drops
    /// blanks, the server de-duplicates case-insensitively keeping the first
    /// spelling, and ORDER IS THE FARMER'S — nothing here sorts. A list rather
    /// than one long line because a phone-width text field holding five crops
    /// cannot show which one the cursor is in. A comma typed into a row still
    /// splits it, exactly as on the web (`FarmProfileDraft.normaliseCrops`).
    @ViewBuilder
    private var cropsEditor: some View {
        Section {
            ForEach(draft.crops.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Култура", text: cropBinding(index), prompt: Text("—"))
                    // A slug from an older row (`wheat`) is shown as stored —
                    // editing a translation would rewrite the value — with
                    // what the profile page will show it as.
                    if let shown = CommodityName.freeText(draft.crops[index]),
                       shown != draft.crops[index] {
                        Text("Показва се като «\(shown)»")
                            .font(.caption).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            .onDelete { draft.crops.remove(atOffsets: $0) }

            HStack {
                TextField("Нова култура", text: $newCrop)
                    .onSubmit(addCrop)
                Button("Добави", action: addCrop)
                    .buttonStyle(.borderless)
                    .disabled(newCrop.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Произвеждани култури")
        } footer: {
            Text("Например „пшеница“, „слънчоглед“, „царевица“. Плъзнете наляво, за да премахнете.")
        }
    }

    /// Index-based, and guarded: `onDelete` can remove a row while its field
    /// still holds focus, and a stale index would trap.
    private func cropBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.crops.indices.contains(index) ? draft.crops[index] : "" },
            set: { if draft.crops.indices.contains(index) { draft.crops[index] = $0 } }
        )
    }

    private func addCrop() {
        let parts = newCrop.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        draft.crops.append(contentsOf: parts)
        newCrop = ""
    }

    // MARK: Conflict

    /// The 409, said plainly, with the one way forward.
    ///
    /// NOT a «Запази» retry and not «Отхвърли»: the first would need the
    /// newer version, which only a reload legitimately gives, and the second
    /// throws away what was typed. Reload keeps it (`FarmProfileRebase`).
    private var conflictSection: some View {
        Section {
            Text(FarmProfileConflict.message)
                .font(.footnote).foregroundStyle(Palette.error)
            Text(FarmProfileConflict.advice)
                .font(.footnote).foregroundStyle(Palette.secondaryText)
            if reloading {
                ProgressView()
            } else {
                Button(FarmProfileConflict.reload) { Task { await reloadAfterConflict() } }
            }
        }
    }

    private func reloadAfterConflict() async {
        reloading = true
        defer { reloading = false }
        do {
            let fresh = try await reload()
            // The edits move onto what is stored now; untouched fields take
            // the other person's values, so the next save does not write
            // their change back over with the stale one.
            let rebased = FarmProfileRebase.rebase(draft, from: original, onto: fresh)
            original = fresh
            draft = rebased.draft
            conflicted = false
            failure = nil
            reloadNotes = rebased.collisions
            AccessibilityNotification.Announcement(FarmProfileConflict.reloaded).post()
        } catch {
            // Stays in the conflict state: the version is still stale, so
            // «Запази» stays off and «Презареди» stays offered.
            failure = UserMessage.text(for: error)
        }
    }

    // MARK: Save

    private func submit() async {
        // A crop left in «Нова култура» was meant: the farmer typed it and
        // pressed Запази. Dropping it would be the silent loss the guard on
        // Отказ exists to prevent.
        addCrop()
        failure = nil
        switch FarmProfileUpdate.build(original: original, draft: draft) {
        case .failure(let refusal):
            problems = refusal.problems
            return
        case .success(let body):
            problems = []
            saving = true
            defer { saving = false }
            do {
                try await save(body, draft)
                AccessibilityNotification.Announcement(FarmProfileSaveReport.saved).post()
                dismiss()
            } catch APIClient.APIError.conflict {
                // 409 STALE_DATA: someone saved since this sheet opened.
                // Nothing was written; everything typed stays; NO retry.
                reloadNotes = nil
                conflicted = true
                feedback.refused()
                AccessibilityNotification.Announcement(FarmProfileConflict.message).post()
            } catch {
                // Stays open with everything typed. A refused write whose
                // message has gone reads as a write that worked — #921, in a
                // different form. A 403 lands here as «Нямате права за това
                // действие.» through `UserMessage`.
                failure = UserMessage.text(for: error)
                feedback.refused()
            }
        }
    }
}

// MARK: - Privacy

extension View {
    /// Cover the screen while the app is not active — the app switcher.
    ///
    /// iOS photographs the screen as the app leaves the foreground and shows
    /// that picture in the switcher, to anyone holding the phone. On these
    /// two screens the picture would hold an ЕИК, a УРН, an address and — if
    /// revealed — an ЕГН. The overlay draws on `.inactive`, which is the
    /// phase the snapshot is taken in.
    ///
    /// Local to the farm profile rather than app-wide: it is the one screen
    /// whose content is a person's identity documents, and covering every
    /// screen would make the switcher useless for the farmer's own work.
    func privacyCover() -> some View {
        modifier(PrivacyCover())
    }
}

private struct PrivacyCover: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.overlay {
            if phase != .active {
                ZStack {
                    Palette.Surface.page
                    Label("Профил на стопанството", systemImage: "lock")
                        .foregroundStyle(Palette.secondaryText)
                }
                .ignoresSafeArea()
            }
        }
    }
}
