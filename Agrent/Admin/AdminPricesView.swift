import SwiftUI

/// Админ → «Цени» (#258): the superuser types the day's prices, and each one
/// replaces the API's price for every farm until it is cleared (owner,
/// 2026-10-10; agri-saas #1587).
///
/// Offered only in the platform farm, to its owner or admins (`Farm
/// .isPlatform`). The server checks again on every request.
struct AdminPricesView: View {
    @State private var store = AdminPricesStore()
    /// The row whose «Изчисти» is waiting for a yes.
    @State private var confirmingClear: AdminPricesAPI.Overrides.Row?

    var body: some View {
        content
            .inlineTitle("Цени")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await store.save() }
                    } label: {
                        if store.saving { ProgressView() } else { Text("Запази") }
                    }
                    .disabled(!store.canSave)
                    .accessibilityLabel("Запази")
                    .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .confirmationDialog(
                clearTitle, isPresented: Binding(
                    get: { confirmingClear != nil },
                    set: { if !$0 { confirmingClear = nil } }),
                titleVisibility: .visible, presenting: confirmingClear
            ) { row in
                Button("Изчисти", role: .destructive) { Task { await store.clear(row.commodity) } }
                Button("Отказ", role: .cancel) {}
            } message: { row in
                Text(Self.clearMessage(row))
            }
            .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.load() }
        case .loaded:
            PageForm {
                Section {
                    DatePicker("Ден", selection: $store.day, in: ...Date(), displayedComponents: .date)
                        .tint(Palette.DatePill.tint)
                } footer: {
                    SectionFooter(Self.dayNote)
                }
                rows("Култури", store.cropRows)
                rows("Торове и гориво", store.inputRows)
                notes
            }
        }
    }

    private func rows(_ title: String, _ rows: [AdminPricesAPI.Overrides.Row]) -> some View {
        Section(titled: title) {
            ForEach(rows) { row in
                AdminPriceRow(
                    row: row,
                    text: Binding(
                        get: { store.texts[row.commodity] ?? "" },
                        set: { store.texts[row.commodity] = $0 }),
                    problem: store.problems[row.commodity],
                    farFromAPI: store.isFarFromAPI(row),
                    clearing: store.clearing == row.commodity,
                    clear: { confirmingClear = row }
                )
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let failure = store.failure {
            Section {
                Text(failure)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let saved = store.savedNote {
            Section {
                Label(saved, systemImage: "checkmark.circle")
                    .foregroundStyle(Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var clearTitle: String {
        guard let row = confirmingClear else { return "" }
        return "Да се изчисти ли ръчната цена за \(AdminPricesStore.name(row.commodity))?"
    }

    /// What clearing does, said before it happens. On a commodity with no
    /// feed it leaves every farm's calculator with no price at all, which
    /// would otherwise look like data loss (#1587 §5b).
    static func clearMessage(_ row: AdminPricesAPI.Overrides.Row) -> String {
        row.apiFeed.exists
            ? "Всички стопанства отново ще виждат цената от външния източник. Въведените цени остават в историята."
            : "\(AdminPricesStore.name(row.commodity)) няма външен източник: калкулаторът на всички стопанства ще остане без цена за нея."
    }

    private static let dayNote =
        "Въведената цена заменя цената от външния източник за всички стопанства, докато не бъде изчистена."
}

/// One commodity: its field, what it is typed in, and what it would replace.
private struct AdminPriceRow: View {
    let row: AdminPricesAPI.Overrides.Row
    @Binding var text: String
    let problem: AdminPricesStore.Problem?
    let farFromAPI: Bool
    let clearing: Bool
    let clear: () -> Void

    private var name: String { AdminPricesStore.name(row.commodity) }
    private var unit: String { AdminPricesStore.unitLabel(AdminPricesStore.entryUnit(row.commodity)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldRow("\(name), \(unit)") {
                TextField("0", text: $text, prompt: .fieldPrompt("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            typedLine
            apiLine
            warnings
        }
    }

    /// The price typed and still in force, with the way to end it.
    @ViewBuilder
    private var typedLine: some View {
        if let typed = row.typed {
            AdaptiveRow {
                Text("В сила: \(Self.quote(typed))")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if clearing {
                    ProgressView()
                } else {
                    Button("Изчисти", action: clear)
                        .font(.footnote)
                        // Borderless, so only the words clear it: in a form
                        // row a plain button takes the whole row, field and all.
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Изчисти ръчната цена за \(name)")
                }
            }
        }
    }

    /// What the typed price replaces. «Няма външен източник» is a different
    /// statement from «няма текуща цена», and the two are said differently.
    private var apiLine: some View {
        Text(apiText)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var apiText: String {
        if let api = row.api { return "Източник: \(Self.quote(api))" }
        return row.apiFeed.exists
            ? "Източникът няма текуща цена."
            : "Няма външен източник: ръчната цена е единствената."
    }

    @ViewBuilder
    private var warnings: some View {
        if let problem {
            Text(problem == .unreadable ? "Не е число." : "Цената трябва да е над нула.")
                .font(.footnote)
                .foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if farFromAPI {
            Text("Далеч от цената на източника. Проверете, преди да запазите.")
                .font(.footnote)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «212,50 €/т, 9 октомври».
    static func quote(_ quote: AdminPricesAPI.Overrides.Quote) -> String {
        let day = BgDate.parseISODay(quote.date).map { BgDate.rowDay($0) } ?? quote.date
        return "\(quote.value.text(scale: 2)) \(AdminPricesStore.unitLabel(quote.unit)), \(day)"
    }
}
