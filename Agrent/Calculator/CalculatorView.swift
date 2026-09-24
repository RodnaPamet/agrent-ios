import SwiftUI

struct CalculatorView: View {
    @State private var store = CalculatorStore()
    @State private var costs = CostsStore()
    @State private var addingCost = false

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let age = store.state.freshness?.ageDescription {
                        StaleBanner(age: age)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { newCostButton }
            .navigationTitle("Калкулатор")
            .appMenu()
            .sheet(isPresented: $addingCost) {
                NewCostView {
                    Task {
                        await costs.load()
                        await store.load()
                    }
                }
            }
            .task {
                if store.state.value == nil { await store.load() }
                if costs.state.value == nil { await costs.load() }
            }
        }
    }

    /// A full-width target at the bottom, the same shape as the journal's
    /// "Нов запис" — a gloved thumb reaches the bottom of a phone, and the
    /// top-right corner is the hardest place on the device to hit
    /// one-handed. DESIGN.md asks for one pass across all five tabs rather
    /// than each screen inventing its own affordance.
    ///
    /// Shown even when the report is EMPTY, which is the case this tenant
    /// is actually in: the calculator has nothing to compute until there is
    /// a season with sown area, and "nothing to show" is exactly the
    /// moment an operator wants to put something in. A screen that says
    /// "няма какво да се изчисли" and offers no way to change that is a
    /// dead end.
    private var newCostButton: some View {
        Button {
            addingCost = true
        } label: {
            Text("Нов разход").frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let payload, _) where payload.rows.isEmpty:
            // Says WHY rather than just "empty". This is the state production
            // actually returns today, and "no data" without a reason reads as
            // a broken screen.
            //
            // The costs list sits below it even here, and that placement is
            // load-bearing rather than tidy: the grain routes have no
            // idempotency, so `NewCostView` tells an operator whose save
            // timed out to CHECK THIS LIST before entering it again. Advice
            // to look somewhere that does not exist is worse than no advice.
            List {
                // NOT the `EmptyState` component. It is built to fill a
                // screen — centred, with a large icon — and a List row
                // gives it a row's height instead, which clipped the icon
                // to a grey sliver. A component that assumes the whole
                // screen does not become a section by being put in one.
                Section("Стойност") {
                    Text("Няма какво да се изчисли")
                        .font(.headline)
                    Text("Калкулаторът показва стойност само когато има сезон със засети площи. За това стопанство още няма такива.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                costsSection
            }
            .refreshable {
                await PullToRefresh.bounded {
                    await store.load()
                    await costs.load()
                }
            }

        case .loaded(let payload, _):
            List {
                farmSection(payload)
                ForEach(payload.rows) { row in
                    rowSection(row)
                }
                costsSection
                footnotes(payload)
            }
            .refreshable {
                await PullToRefresh.bounded {
                    await store.load()
                    await costs.load()
                }
            }
        }
    }

    // MARK: - Costs

    /// What has been entered, so a save can be CHECKED.
    ///
    /// Without idempotency a duplicate is permanent, so an operator whose
    /// save timed out must be able to see whether it landed before deciding
    /// to try again. That makes this list part of the write path rather
    /// than a nice-to-have beside it.
    @ViewBuilder
    private var costsSection: some View {
        switch costs.state {
        case .loading:
            Section("Разходи") { ProgressView() }

        case .failed(let message):
            Section("Разходи") {
                Text(message).font(.footnote).foregroundStyle(Palette.error)
            }

        case .loaded(let page, _) where page.items.isEmpty:
            Section("Разходи") {
                Text("Още няма въведени разходи.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .loaded(let page, _):
            Section(header: Text("Разходи"), footer: costsFooter(page)) {
                ForEach(page.items) { cost in CostRow(cost: cost) }
            }
        }
    }

    @ViewBuilder
    private func costsFooter(_ page: CostPage) -> some View {
        if page.truncated {
            // A capped list looks exactly like a complete short one, and on
            // the screen someone checks a save against, that is the
            // difference between "it did not save" and "you cannot see it
            // from here".
            Text("Списъкът е съкратен от сървъра. Не всички разходи се показват.")
        } else if let total = page.totalCount, total != page.items.count {
            Text("Показани \(page.items.count) от " + Plural.bg(total, "разход", "разхода") + ".")
        }
    }
    // MARK: - Farm totals

    @ViewBuilder
    private func farmSection(_ payload: CalculatorPayload) -> some View {
        if !payload.farm.totals.isEmpty {
            Section("Общо за стопанството") {
                ForEach(payload.farm.totals) { total in
                    LabeledContent(total.currency) {
                        Text(Money.text(total.netWorth, total.currency))
                            .font(.headline)
                    }
                    if !total.refusedCommodities.isEmpty {
                        // Naming what is NOT in the total matters more than the
                        // total: a number that silently omits a crop reads as
                        // complete.
                        Text("Без: \(total.refusedCommodities.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - One commodity

    @ViewBuilder
    private func rowSection(_ row: CalculatorRow) -> some View {
        Section {
            if let net = row.netWorth {
                LabeledContent("Нетна стойност") {
                    Text(Money.text(net, row.priceCurrency))
                        .font(.headline)
                }
            } else if let reason = row.refusalText {
                // The server's own sentence, in the SAME weight as any other
                // row. The calculator declining to invent a number is the
                // product working; colouring it like a fault taught the
                // operator to distrust a correct answer.
                RefusalNote(text: reason)
            }

            // areaDca comes from the payload — never recomputed from
            // standingCropAreaHa. See PerArea's header.
            LabeledContent("Площ") {
                Text("\(Num.text(row.perArea.areaDca)) дка")
            }
            LabeledContent("Очаквана реколта") {
                Text("\(Num.text(row.expectedTonnes)) т")
            }

            if let value = row.perArea.standingValuePerDca {
                LabeledContent("Стойност / дка") { Text(Num.text(value)) }
            }
            if let cost = row.perArea.attributableCostPerDca {
                LabeledContent("Разход / дка") { Text(Num.text(cost)) }
            }
            if let margin = row.perArea.marginPerDca {
                LabeledContent("Марж / дка") { Text(Num.text(margin)) }
            }

            if let breakEven = row.breakEven.breakEvenPricePerTonne {
                LabeledContent("Себестойност / т") {
                    Text(Money.text(breakEven, row.breakEven.currency))
                }
            }
            if let cover = row.breakEven.coverPercent {
                LabeledContent("Покритие") {
                    Text("\(Num.text(cover))%")
                        .foregroundStyle(row.breakEven.covered == true ? .green : .orange)
                }
            }

            if let observed = row.priceObservedAt {
                // A yyyy-mm-dd STRING, shown verbatim. Parsing it into a Date
                // to reformat would be the trap this model exists to avoid.
                LabeledContent("Цена от") {
                    Text(observed).foregroundStyle(.secondary)
                }
            }

            if row.showProduceRent {
                LabeledContent("Рента в натура") {
                    Text("\(Num.text(row.rentCostProduceKg)) кг")
                }
            }
            if row.rentCurrencyUnknown {
                RefusalNote(text: "Валутата на рентата е неизвестна.",
                            icon: "questionmark.circle")
            }
        } header: {
            HStack {
                Text(CommodityName.canonical(row.commodity) ?? row.commodity)
                Spacer()
                UncertaintyBadge(row.netUncertainty)
            }
        }
    }

    // MARK: - What the figures leave out

    @ViewBuilder
    private func footnotes(_ payload: CalculatorPayload) -> some View {
        if !payload.exclusions.isEmpty || !payload.unvalued.isClean || payload.truncated {
            Section("Извън изчислението") {
                ForEach(payload.exclusions.all) { item in
                    Text(item.label).font(.footnote)
                }
                if payload.unvalued.noUnitCost > 0 {
                    Text("\(payload.unvalued.noUnitCost) без единична цена").font(.footnote)
                }
                if payload.unvalued.unitMismatch > 0 {
                    Text("\(payload.unvalued.unitMismatch) с несъвпадаща мерна единица").font(.footnote)
                }
                if payload.truncated {
                    RefusalNote(text: "Списъкът е съкратен.", icon: "ellipsis.circle")
                }
            }
        }
    }
}

/// Only shown when it is not `.exact` — a badge on every row is a badge
/// nobody reads.
private struct UncertaintyBadge: View {
    let value: Uncertainty

    init(_ value: Uncertainty) { self.value = value }

    var body: some View {
        if let label {
            CategoryChip(text: label, foreground: tint, background: tint.opacity(0.14))
        }
    }

    private var label: String? {
        switch value {
        case .exact: nil
        case .allocated: "разпределено"
        case .partial: "частично"
        case .atLeast: "най-малко"
        case .atMost: "най-много"
        case .refused: "няма данни"
        case .unknown: "неясно"
        }
    }

    /// Deliberately restrained. "atLeast" and "refused" describe how a
    /// figure was derived, not that anything went wrong — the design review
    /// separated refusal from error precisely because colouring them alike
    /// trains people to ignore both. Nothing here is `Palette.error`, which
    /// is reserved for things that are actually broken.
    private var tint: Color {
        switch value {
        case .exact, .allocated: .secondary
        case .atLeast, .atMost, .partial, .refused, .unknown: Palette.accentDeep
        }
    }
}

enum Num {
    /// Up to 2dp, trailing zeros dropped. The payload already rounds where it
    /// means to, so this must not round further and disagree with it.
    ///
    /// FORCED TO bg_BG, like every other formatter in this app.
    ///
    /// Without a locale this reads the PROCESS's, which is not the one the
    /// app renders in. `AgrentApp` sets the SwiftUI environment to bg_BG,
    /// but that reaches `Text`, not a String built here and interpolated
    /// into a sentence — so «32,4 ха» became «32.4 ха» the moment the
    /// device's region was not European, and the same number appeared with
    /// two different separators on one screen depending on which of the two
    /// paths drew it.
    ///
    /// Caught by CI rather than by me: two tests asserting «32,4» passed on
    /// this machine, which reports en-BG, and failed on a runner that does
    /// not. That is the same trap as the journal printing "11 September" —
    /// a locale inherited rather than chosen. `BgDate.locale` is where this
    /// app already decided the answer.
    static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))
            .grouping(.automatic).locale(BgDate.locale))
    }
}

enum Money {
    /// Currency shown as the payload's own code rather than a symbol: the
    /// payload can carry an "UNKNOWN" sentinel, and rendering that as a
    /// currency symbol would invent a currency.
    ///
    /// ── MONEY IS ALWAYS TWO DECIMALS ──
    ///
    /// This used `Num.text`, whose precision is `0...2` — trailing zeros
    /// dropped. Correct for an area or a tonnage, wrong for money: the
    /// farm's net worth rendered as `12 691,8 EUR` where the books say
    /// `12 691,80`. Seen on the device the moment the calculator started
    /// returning real figures.
    ///
    /// It is the same defect as the one in `WireDecimal`, reached from the
    /// other direction — there the server dropped the zero, here the client
    /// did. A money figure that is not at its currency's scale reads as an
    /// approximation, and on a screen whose whole job is reconciling
    /// against a ledger that is the difference between a number someone
    /// can check and one they have to think about.
    static func text(_ value: Double, _ currency: String?) -> String {
        // bg_BG for the same reason as `Num.text` — a ledger figure must
        // not change separator with the device's region.
        let amount = value.formatted(
            .number.precision(.fractionLength(2)).grouping(.automatic)
                .locale(BgDate.locale)
        )
        guard let currency, !currency.isEmpty else { return amount }
        return "\(amount) \(currency)"
    }
}

struct CostRow: View {
    let cost: CostEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cost.category.label).font(.subheadline.weight(.medium))
                Text(BgDate.dayMonth(cost.incurredOn))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Padded back to the column's scale: 1.00 arrives as 1, and
            // "1 лв" on a books screen is not what the ledger says.
            Text("\(cost.amountText) \(cost.currency)")
                .font(.subheadline.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            cost.category.label,
            "\(cost.amountText) \(cost.currency)",
            BgDate.full(cost.incurredOn),
            cost.supplier,
        ]))
    }
}
