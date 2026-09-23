import SwiftUI
import Observation

/// Add a real product to the catalogue.
///
/// ── Why this screen exists ──
///
/// 22 of this tenant's 24 products are named `Generic …`, with no active
/// ingredient and no PPP registration number. They are seeded ARCHETYPES
/// and they are deliberate — shipping a proprietary label database would
/// be a licensing problem, and operators are meant to replace them.
///
/// Nothing replaced them, and the phone is where sprays get recorded. So
/// every application filed from a field inherits a placeholder into the
/// column the ДНЕВНИК heads «Употребено средство за РЗ /търговско
/// наименование/» — a regulated column on a register kept under
/// чл. 115а ЗЗР, with nothing marking it as a placeholder.
///
/// This is the surface that stops new rows arriving that way.
struct NewProductView: View {
    /// The product just created, handed back so the caller can select it
    /// without a round trip.
    let onCreated: (InputItem) -> Void

    /// Everything already in the catalogue — for the duplicate check.
    let existing: [InputItem]

    @Environment(\.dismiss) private var dismiss
    @State private var store = NewProductStore()

    @State private var name = ""
    @State private var category: ItemCategory = .pesticide
    @State private var unit: Unit?
    @State private var activeIngredient = ""
    @State private var pppNo = ""
    @State private var quarantineText = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Item` has an INDEX on (tenantId, name), not a unique constraint,
    /// and `createItem` does no existence check — so a duplicate is
    /// accepted silently and sprays then split across two rows that look
    /// identical on the register. The server will not stop this; this is
    /// the only place it can be stopped.
    private var duplicate: InputItem? {
        guard !trimmedName.isEmpty else { return nil }
        return existing.first {
            $0.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
    }

    /// Stricter than the server, deliberately.
    ///
    /// `POST /items` accepts `pppRegistrationNo` and `quarantinePeriodDays`
    /// as optional for every category. The unassisted version of this form
    /// has already been tried on production, once, and the result is still
    /// in the catalogue:
    ///
    ///     Roubdup · PESTICIDE · ppp=null · quarantine=null · ai=null   ×2
    ///
    /// Created twice, trade name misspelled, every regulated field empty.
    /// For a PESTICIDE `quarantinePeriodDays` feeds column 8 of the
    /// ХИМИЧНИ ОБРАБОТКИ table and the earliest-harvest date in column 9,
    /// so a spray filed against that row prints those columns blank.
    ///
    /// Only for PESTICIDE. A fertiliser has no ЗЗР registration number,
    /// and requiring one would block a legitimate entry — which is the
    /// mistake of applying a rule past the case that justified it.
    private var missingRegulatory: Bool {
        guard category.requiresRegistrationDetails else { return false }
        return blankToNil(pppNo) == nil
            || Int(quarantineText.trimmingCharacters(in: .whitespaces)) == nil
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 200 && unit != nil
            && duplicate == nil && !missingRegulatory && !store.isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Наименование") {
                    TextField("Търговско наименование", text: $name)
                        .textInputAutocapitalization(.words)
                    if let duplicate {
                        Label(
                            "«\(duplicate.name)» вече съществува. Изберете го, вместо да го създавате втори път.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Класификация") {
                    // `.navigationLink`, so the options are read at full
                    // width on their own screen. A menu picker renders the
                    // selection inside the row, where «Препарат за РЗ»
                    // clipped to «Препа…за РЗ» — and these labels cannot
                    // get much shorter without becoming abbreviations
                    // nobody uses.
                    Picker("Вид", selection: $category) {
                        ForEach(ItemCategory.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.navigationLink)

                    switch store.units {
                    case .loading:
                        ProgressView()
                    case .failed(let message):
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    case .loaded(let units, _):
                        // Required, and it must RESOLVE — `createItem`
                        // throws "Default unit not found." for an id it
                        // cannot look up, so this is a picker and never a
                        // text field.
                        Picker("Единица", selection: $unit) {
                            Text("— изберете —").tag(Unit?.none)
                            ForEach(units) { Text($0.pickerLabel).tag(Unit?.some($0)) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }

                registerSection
            }
            .navigationTitle("Нов продукт")
            // LARGE, and measured rather than preferred. Inline, this bar
            // holds Отказ and Запази as pills and leaves the title about
            // five characters — «Нов проду…» first, then «Проду…» after I
            // shortened it to seven. Shortening the words was treating the
            // symptom; the title had nowhere to go. Large puts it on its
            // own line with the full width.
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }.disabled(store.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView()
                    } else {
                        Button("Запази") { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
            .task { await store.loadUnits() }
            .alert("Неуспешно записване", isPresented: .init(
                get: { store.failure != nil },
                set: { if !$0 { store.clearFailure() } }
            )) {
                Button("Добре", role: .cancel) { store.clearFailure() }
            } message: {
                Text(store.failure ?? "")
            }
        }
    }

    /// The three fields the register prints, asked for rather than hidden
    /// under "advanced".
    ///
    /// They are optional to the SERVER and not optional to the document.
    /// `quarantinePeriodDays` feeds column 8 of the ХИМИЧНИ ОБРАБОТКИ table
    /// and the earliest-harvest date derived from it; `pppRegistrationNo`
    /// and `activeIngredient` have columns of their own. A product created
    /// with only a trade name fills one of them and leaves the rest as
    /// empty as the archetype it was meant to replace.
    @ViewBuilder
    private var registerSection: some View {
        if category.appearsOnTheRegister {
            Section {
                TextField("Активно вещество", text: $activeIngredient)
                TextField("Рег. № по ЗЗР", text: $pppNo)
                    .textInputAutocapitalization(.characters)
                LabeledContent(category == .pesticide ? "Карантина (дни) ∗"
                                                      : "Карантина (дни)") {
                    TextField("—", text: $quarantineText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("За дневника")
            } footer: {
                if category == .pesticide {
                    Text("Рег. № и карантинният срок са задължителни за препарат "
                       + "за РЗ: те се отпечатват в колони 4, 8 и 9 на дневника "
                       + "за химични обработки. Без тях записът се подава с "
                       + "празни регулаторни колони.")
                } else {
                    Text("Тези полета се отпечатват в дневника за химични "
                       + "обработки, ако са попълнени.")
                }
            }
        }
    }

    private func save() async {
        let quarantine = Int(quarantineText.trimmingCharacters(in: .whitespaces))
        let draft = CreateItem(
            name: trimmedName,
            category: category.rawValue,
            defaultUnitId: unit?.id ?? "",
            // Empty is NOT the same as absent. A blank field means "not
            // supplied", which the column already is; sending "" would
            // write an empty string where null is the honest value.
            activeIngredient: blankToNil(activeIngredient),
            pppRegistrationNo: blankToNil(pppNo),
            quarantinePeriodDays: quarantine
        )
        if let created = await store.save(draft) {
            onCreated(created)
            dismiss()
        }
    }

    private func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Observable
@MainActor
final class NewProductStore {
    private(set) var units: LoadState<[Unit]> = .loading
    private(set) var isSaving = false
    private(set) var failure: String?

    /// ALL units, not the RATE four. A dose is л/дка; a product is stocked
    /// in litres or kilograms.
    func loadUnits() async {
        guard units.value == nil else { return }
        units = await CachedResource.load(LocationsAPI.allUnitsPath) {
            try await LocationsAPI.decodeUnits(from: $0)
        }
    }

    /// Never retried automatically. A replay creates a SECOND product with
    /// the same name — no unique constraint, no existence check server-side
    /// — and two identical-looking rows on a register is worse than a save
    /// the person knows failed.
    func save(_ draft: CreateItem) async -> InputItem? {
        isSaving = true
        defer { isSaving = false }
        do {
            return try await LocationsAPI.createItem(draft)
        } catch {
            failure = UserMessage.text(for: error)
            return nil
        }
    }

    func clearFailure() { failure = nil }
}
