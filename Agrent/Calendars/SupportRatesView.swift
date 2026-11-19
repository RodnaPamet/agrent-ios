import SwiftUI

/// «Подпомагане» (#638, owner 2026-11-17): the coupled-support rates per дка,
/// one row per scheme, in euro the server converted under the vine card's
/// marker. Under «Знания», for every role.
struct SupportRatesView: View {
    @State private var store = AgroBenchmarksStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RoutedStack {
            List {
                Section {
                    Text(BenchmarkWords.supportIntro)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .pageRow()
                switch store.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .pageRow()
                case .failed(let message):
                    ErrorState(message: message) { await store.load() }
                        .pageRow()
                case .loaded(let figures, _):
                    // The source line is per row: one list now holds the 2025
                    // order in euro and the 2024 protein rate in leva.
                    Section {
                        ForEach(figures.shownRates) { rate in
                            row(rate).pageRow()
                        }
                    }
                }
            }
            .pageBackground()
            .inlineTitle(BenchmarkWords.supportTitle)
            .task { await store.load() }
            .floatingClose { dismiss() }
        }
    }

    private func row(_ rate: AgroBenchmarks.Rate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rate.title)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let cents = rate.perDaEurCents {
                Text(BenchmarkWords.perDa(cents))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
            }
            if let over = rate.perDaOver30EurCents {
                Text(BenchmarkWords.over300(over))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
            }
            Text(BenchmarkWords.rateNote(rate))
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
