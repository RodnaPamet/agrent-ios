import Charts
import SwiftUI

/// «Табло» — the blocks this farmer chose, in the order they chose.
///
/// ── An empty block is not drawn at all ──
///
/// The owner's instruction, and the contract makes it the only honest option:
/// `enabledModules` uses ABSENCE, so a gated tenant receives empty arrays
/// rather than missing keys, and nothing in the payload distinguishes "you do
/// not have this module" from "nothing is recorded yet". «Няма записи» under a
/// heading would tell a farmer his data is missing when the feature simply is
/// not his. So a block with nothing to say renders nothing, and the picker is
/// where you learn a block exists.
struct DashboardView: View {
    @State private var store = DashboardStore()
    @State private var preferences = DashboardPreferences.shared
    @State private var editing = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(preferences.blocks) { block in
                    content(for: block)
                }

                // The one thing always shown. Without it a farmer who turned
                // every block off, or whose every block is empty, gets a blank
                // screen with no way back — and the picker is in the toolbar,
                // which is exactly where somebody does not look when they think
                // the app is broken.
                if visibleBlockCount == 0 {
                    RefusalNote(
                        text: "Няма избрани блокове. Изберете какво да се показва.",
                        icon: "square.grid.2x2")
                        .pageRow()
                }
            }
            .listStyle(.plain)
            .pageBackground()
            .navigationTitle("Табло")
            .appMenu()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editing = true
                    } label: {
                        Label("Избор на блокове", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $editing) {
                DashboardBlockPicker(preferences: preferences) {
                    // A block turned on needs its data, and the store fetches
                    // only what is on screen — so a change of selection is a
                    // reason to load, not only to re-render.
                    Task { await store.load() }
                }
            }
            .refreshable { await PullToRefresh.bounded { await store.refresh() } }
            .task { await store.load() }
        }
    }

    /// How many blocks will actually draw something. Counted from the same
    /// predicates the blocks use, so the empty-state note cannot disagree with
    /// the screen.
    private var visibleBlockCount: Int {
        preferences.blocks.count { hasContent($0) }
    }

    /// A block that is empty BECAUSE THE FARM DOES NOT HAVE THE MODULE.
    ///
    /// Returns the sentence to show, or nil when there is nothing honest to
    /// say. Two conditions, both required: the block must have a gating module
    /// this app is confident about (see `DashboardBlock.gatingModule`), and the
    /// payload must have arrived — `enabledModules` cannot be consulted before
    /// it loads, and guessing while loading would flash "not enabled" at
    /// somebody who has it.
    ///
    /// ── Why this replaced hiding ──
    ///
    /// Hiding was right while "gated" and "no data" were indistinguishable:
    /// «Няма записи» under a heading tells a farmer his data is missing when
    /// the feature simply is not his. The module enum makes the distinction
    /// readable, and the owner chose to say it — because hiding is also how a
    /// farm concludes a feature does not exist and stops asking for it.
    private func disabledNote(for block: DashboardBlock) -> String? {
        guard let module = block.gatingModule,
              let payload = store.ag.value,
              !payload.isEnabled(module)
        else { return nil }
        return "Не е включено за това стопанство."
    }

    private func hasContent(_ block: DashboardBlock) -> Bool {
        // A block that can EXPLAIN its emptiness has something to show.
        if disabledNote(for: block) != nil { return true }
        return hasData(block)
    }

    private func hasData(_ block: DashboardBlock) -> Bool {
        switch block {
        case .briefing: store.briefing.value != nil || store.briefing.isFailed
        case .grainPrice: store.chosenPriceSeries != nil || store.prices.isFailed
        case .journal: !(store.ag.value?.recentJournal.isEmpty ?? true)
        case .taskTrend: !(store.taskTrend.value?.trend.isEmpty ?? true)
        case .tasks: !(store.ag.value?.myTasks.isEmpty ?? true)
        case .lowStock: !(store.ag.value?.lowStock.isEmpty ?? true)
        case .achievements: store.ag.value?.achievements != nil
        }
    }

    @ViewBuilder
    private func content(for block: DashboardBlock) -> some View {
        // THE EXPLANATION WINS over the block's own body. A gated module has no
        // data by definition, so every section below would render nothing and
        // the reason would never be seen.
        if let note = disabledNote(for: block) {
            Section(block.label) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .pageRow()
            }
        } else {
            body(for: block)
        }
    }

    @ViewBuilder
    private func body(for block: DashboardBlock) -> some View {
        switch block {
        case .briefing: briefingSection
        case .grainPrice: priceSection
        case .journal: journalSection
        case .taskTrend: taskTrendSection
        case .tasks: tasksSection
        case .lowStock: lowStockSection
        case .achievements: achievementsSection
        }
    }

    // MARK: - Сателитно обобщение

    /// The three flags name the cause. A single empty card would say only that
    /// there is nothing, which is the one thing a farmer already knows.
    @ViewBuilder
    private var briefingSection: some View {
        if let payload = store.briefing.value {
            Section("Сателитно обобщение") {
                if let briefing = payload.briefing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(briefing.headline).font(.headline)
                        Text(briefing.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11y.sentence([briefing.headline, briefing.summary]))
                    .pageRow()

                    // Highest priority first, and `unknown` last — an
                    // unrecognised value is not evidence of urgency.
                    ForEach(briefing.actions.sorted { $0.priority.rank < $1.priority.rank }) {
                        action in
                        actionRow(action).pageRow()
                    }
                } else if let absence = payload.absence {
                    Text(Self.text(for: absence))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .pageRow()
                }
            }
        } else if store.briefing.isFailed {
            Section("Сателитно обобщение") {
                Text(store.briefing.failureText ?? "Грешка.")
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .pageRow()
            }
        }
    }

    private func actionRow(_ action: BriefingAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.action).font(.subheadline)
                // Nil means THE WHOLE FARM, which is a scope rather than a
                // gap — so no placeholder, and no label for the absence.
                if let field = action.field {
                    Text(field).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if action.priority != .unknown {
                CategoryChip(
                    text: action.priority.label,
                    foreground: Palette.Chip.activityText,
                    background: Palette.Chip.activityFill)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            action.action,
            action.field,
            action.priority == .unknown ? nil : action.priority.label,
        ]))
    }

    private static func text(for absence: FieldBriefingPayload.Absence) -> String {
        switch absence {
        // Three different sentences, because the server carries three flags for
        // exactly this and `briefing: null` alone says none of them. The first
        // two are somebody else's to fix; the third may fix itself.
        case .noModel: "Тази инсталация не е настроена да изготвя обобщения."
        case .noSatelliteCredentials: "Няма достъп до сателитните данни."
        case .imageryUnavailable: "Сателитните снимки не се получиха. Опитайте по-късно."
        case .unexplained: "Няма обобщение за днес."
        }
    }

    // MARK: - Цена на избрана култура

    /// ONE series, named, with how many it stands for — never "the price".
    @ViewBuilder
    private var priceSection: some View {
        if let chosen = store.chosenPriceSeries, let latest = chosen.series.points.last {
            Section(preferences.priceCommodity.label) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Num.text(latest.price)) \(chosen.series.currency)/\(chosen.series.unit)")
                        .font(.title3.weight(.semibold))

                    // The series' own identity, because two Bulgarian diesel
                    // series differ by over fifty per cent and a bare number
                    // would be one of them pretending to be both.
                    Text(A11y.sentence([
                        chosen.series.label,
                        chosen.series.region,
                        chosen.series.stage,
                    ]))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let age = Staleness.days(
                        generatedAt: store.prices.value?.generatedAt ?? Date(),
                        lastObservedAt: chosen.series.lastObservedAt) {
                        Text("Отчетена преди \(Plural.bg(age, "ден", "дни"))")
                            .font(.caption)
                            .foregroundStyle(age >= Staleness.concerning ? .orange : .secondary)
                    }

                    if chosen.outOf > 1 {
                        Text("1 от \(chosen.outOf) серии — вижте Тенденции за всички.")
                            .font(.caption2)
                            // `.tertiary` is 1.73:1 on a white row. This
                            // sentence is the only thing telling a farmer the
                            // number above is one of several.
                            .foregroundStyle(.secondary)
                    }
                }
                .pageRow()
            }
        } else if store.prices.isFailed {
            Section(preferences.priceCommodity.label) {
                Text(store.prices.failureText ?? "Грешка.")
                    .font(.footnote).foregroundStyle(Palette.error).pageRow()
            }
        }
    }

    // MARK: - Последни записи

    @ViewBuilder
    private var journalSection: some View {
        if let entries = store.ag.value?.recentJournal, !entries.isEmpty {
            Section("Последни записи") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline)
                        Text(A11y.sentence([
                            entry.type == .unknown ? nil : entry.type.label,
                            entry.occurredAt.map(BgDate.dayMonth),
                        ]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11y.sentence([
                        entry.title,
                        entry.type == .unknown ? nil : entry.type.label,
                        entry.occurredAt.map(BgDate.dayMonth),
                    ]))
                    .pageRow()
                }
            }
        }
    }

    // MARK: - Задачи: създадени и завършени

    @ViewBuilder
    private var taskTrendSection: some View {
        if let trend = store.taskTrend.value?.trend, !trend.isEmpty {
            Section("Създадени и завършени задачи") {
                Chart {
                    ForEach(trend) { point in
                        if let day = point.date {
                            LineMark(
                                x: .value("Дата", day),
                                y: .value("Брой", point.created))
                            .foregroundStyle(by: .value("Серия", "създадени"))
                            .symbol(by: .value("Серия", "създадени"))
                            .interpolationMethod(.monotone)

                            LineMark(
                                x: .value("Дата", day),
                                y: .value("Брой", point.completed))
                            .foregroundStyle(by: .value("Серия", "завършени"))
                            .symbol(by: .value("Серия", "завършени"))
                            // DASHED, because the two colours are 1.47:1
                            // apart from each other.
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                // COLOUR WAS THE ONLY DIFFERENCE between these two lines, and
                // the two colours are the accent and its pressed state —
                // #A04E1B and #7A3A12 in light, #D4AF37 and #B8860B in dark.
                // Against each other they measure 1.47:1 and 1.55:1. That is
                // not a distinction anyone makes; it is two shades of one
                // brown, and this chart's entire claim is "these two lines
                // are different things".
                //
                // Both are legible against the page — 5.83:1 and 8.60:1 — so
                // nothing was wrong with either colour. They were only ever
                // wrong as a PAIR, which is the same mistake as the neutral
                // chip: two values chosen separately and never compared.
                //
                // The non-colour channel is a dash on one line and a distinct
                // symbol per series. The symbol is the one that reaches the
                // LEGEND — a dash applied to a mark does not — so circle
                // against square is what tells a reader which line is which
                // when the two browns look identical to them.
                .chartForegroundStyleScale([
                    "създадени": Palette.accent,
                    "завършени": Palette.accentDeep,
                ])
                .chartSymbolScale([
                    "създадени": BasicChartSymbolShape.circle,
                    "завършени": BasicChartSymbolShape.square,
                ])
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        if let count = value.as(Int.self) {
                            AxisValueLabel {
                                Text("\(count)").font(.caption2).axisLabelScaling()
                            }
                        }
                    }
                }
                .chartXAxis {
                    // THIS AXIS WAS PRINTING ENGLISH. A bare `AxisMarks` over
                    // a `Date` lets Swift Charts format it from the locale,
                    // the device reports en_BG, and a Bulgarian farmer's
                    // dashboard read "Sep 14". Тенденции goes through
                    // `BgDate` for exactly this reason and says so; this
                    // chart was written later and did not.
                    //
                    // The CI guard could not catch it. It rejects the
                    // `.dateTime` spelling, and the defect here is the
                    // ABSENCE of any format at all.
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(BgDate.dayMonth(date)).font(.caption2).axisLabelScaling()
                            }
                        }
                    }
                }
                .frame(height: 140)
                // Counts, so ZERO IS MEANINGFUL and the axis keeps it — unlike
                // the price chart, where anchoring at zero flattened a year of
                // movement into a straight line. A day with no tasks completed
                // is a fact about that day.
                .chartYScale(domain: .automatic(includesZero: true))
                // The chart itself is not a VoiceOver surface; the numbers are.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11y.sentence([
                    "Задачи за последните \(Plural.bg(trend.count, "ден", "дни"))",
                    "създадени \(trend.reduce(0) { $0 + $1.created })",
                    "завършени \(trend.reduce(0) { $0 + $1.completed })",
                ]))
                .pageRow()
            }
        }
    }

    // MARK: - Blocks the owner turned off, which the picker can turn on

    @ViewBuilder
    private var tasksSection: some View {
        if let tasks = store.ag.value?.myTasks, !tasks.isEmpty {
            Section("Моите задачи") {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.subheadline)
                        Text(A11y.sentence([
                            task.status == .unknown ? nil : task.status.label,
                            task.dueAt.map(BgDate.dayMonth),
                        ]))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .pageRow()
                }
            }
        }
    }

    @ViewBuilder
    private var lowStockSection: some View {
        if let stock = store.ag.value?.lowStock, !stock.isEmpty {
            Section("Ниски наличности") {
                ForEach(stock) { item in
                    HStack {
                        Text(item.name).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(item.quantityText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11y.sentence([item.name, item.quantityText]))
                    .pageRow()
                }
            }
        }
    }

    @ViewBuilder
    private var achievementsSection: some View {
        if let achievements = store.ag.value?.achievements {
            Section("Постижения") {
                Text(A11y.sentence([
                    "Серия \(achievements.streak.current)",
                    "най-добра \(achievements.streak.best)",
                ]))
                .font(.subheadline)
                .pageRow()

                ForEach(achievements.milestones.filter(\.earned)) { milestone in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Palette.accent)
                        Text(milestone.label).font(.subheadline)
                    }
                    .pageRow()
                }
            }
        }
    }
}

/// Which blocks appear, and in what order.
struct DashboardBlockPicker: View {
    let preferences: DashboardPreferences
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Култура", selection: Binding(
                        get: { preferences.priceCommodity },
                        set: { preferences.select($0); onChange() })) {
                        ForEach(ChartableCommodity.allCases.filter { !$0.isInput }) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Цена")
                } footer: {
                    Text("Показва се само ако блокът «\(DashboardBlock.grainPrice.label)» е включен.")
                }

                Section {
                    // Shown in the STORED order, with the off ones after, so
                    // dragging arranges what you actually see.
                    ForEach(ordered) { block in
                        Button {
                            preferences.toggle(block)
                            onChange()
                        } label: {
                            HStack {
                                Label(block.label, systemImage: block.icon)
                                Spacer()
                                if preferences.isOn(block) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .pageRow()
                    }
                } header: {
                    Text("Блокове")
                } footer: {
                    Text("Блок без данни не се показва, дори когато е включен.")
                }
            }
            .listStyle(.insetGrouped)
            .inlineTitle("Табло")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    /// Chosen blocks first in their own order, then the rest — so the list
    /// reads as "what you have, then what you could add".
    private var ordered: [DashboardBlock] {
        preferences.blocks + DashboardBlock.allCases.filter { !preferences.blocks.contains($0) }
    }
}
