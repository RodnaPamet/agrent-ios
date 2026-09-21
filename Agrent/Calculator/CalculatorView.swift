import SwiftUI

struct CalculatorView: View {
    @State private var store = CalculatorStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                content
            }
            .navigationTitle("Калкулатор")
            .task { if store.state.value == nil { await store.load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Неуспешно зареждане", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Опитай пак") { Task { await store.load() } }
            }

        case .loaded(let payload, _) where payload.rows.isEmpty:
            // Says WHY rather than just "empty". This is the state production
            // actually returns today, and "no data" without a reason reads as
            // a broken screen.
            ContentUnavailableView {
                Label("Няма какво да се изчисли", systemImage: "chart.pie")
            } description: {
                Text("Калкулаторът показва стойност само когато има сезон със засети площи. За това стопанство още няма такива.")
            } actions: {
                Button("Опитай пак") { Task { await store.load() } }
            }

        case .loaded(let payload, _):
            List {
                farmSection(payload)
                ForEach(payload.rows) { row in
                    rowSection(row)
                }
                footnotes(payload)
            }
            .refreshable { await store.load() }
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
            } else if let reason = row.netWorthUnavailableReason {
                // The server's own sentence. Shown rather than hidden: a row
                // with no number and no explanation looks like a bug.
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                Text("Валутата на рентата е неизвестна.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text(row.commodity)
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
                    Text("Списъкът е съкратен.").font(.footnote).foregroundStyle(.orange)
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
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
        }
    }

    private var label: String? {
        switch value {
        case .exact: nil
        case .allocated: "разпределено"
        case .atLeast: "най-малко"
        case .refused: "няма данни"
        case .unknown: "неясно"
        }
    }

    private var tint: Color {
        switch value {
        case .exact, .allocated: .secondary
        case .atLeast: .orange
        case .refused, .unknown: .red
        }
    }
}

enum Num {
    /// Up to 2dp, trailing zeros dropped. The payload already rounds where it
    /// means to, so this must not round further and disagree with it.
    static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic))
    }
}

enum Money {
    /// Currency shown as the payload's own code rather than a symbol: the
    /// payload can carry an "UNKNOWN" sentinel, and rendering that as a
    /// currency symbol would invent a currency.
    static func text(_ value: Double, _ currency: String?) -> String {
        guard let currency, !currency.isEmpty else { return Num.text(value) }
        return "\(Num.text(value)) \(currency)"
    }
}
