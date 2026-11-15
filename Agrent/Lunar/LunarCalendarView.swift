import SwiftUI

/// «Лунен календар» (#611): one month at a time, a row per day with its
/// type and the Moon, and the day's advice by crop group on tap. The
/// tradition notice heads the page, as the owner framed it.
struct LunarCalendarView: View {
    @State private var month = LunarAPI.month(containing: Date()).from
    @State private var state: LoadState<[LunarDay]> = .loading
    /// Frost and spray warnings by day (#611; agri-saas #3077). Replaced
    /// whole on each read: a future warning can be withdrawn.
    @State private var warnings = LunarWarnings()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RoutedStack {
            content
                .inlineTitle(LunarWords.title)
                .navigationDestination(for: LunarDay.self) { day in
                    LunarDayView(day: day, warnings: LunarWords.warnings(warnings, on: day.date))
                }
                .task(id: month) { await load() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            monthBar
            switch state {
            case .loading:
                ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ErrorState(message: message) { await load() }
            case .loaded(let days, _):
                List {
                    Section {
                        Text(LunarWords.traditionNotice)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(LunarWords.warningNotes(warnings, farmOpen: FarmPath.openSlug != nil), id: \.self) { note in
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        SectionHeader(LunarWords.traditionTitle)
                    }
                    .pageRow()
                    Section {
                        ForEach(days) { day in
                            NavigationLink(value: day) { row(day) }
                                .pageRow()
                        }
                    }
                }
                .pageBackground()
                .refreshable { await PullToRefresh.bounded { await load() } }
            }
        }
    }

    /// The month, with the one before and after.
    private var monthBar: some View {
        HStack {
            Button {
                step(-1)
            } label: {
                Label("Предишен месец", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityInputLabels(A11y.spokenNames("Предишен месец", "Назад", "Previous month"))
            Spacer()
            Text(BgDate.monthYearTitle(month)).font(.headline)
            Spacer()
            Button {
                step(1)
            } label: {
                Label("Следващ месец", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityInputLabels(A11y.spokenNames("Следващ месец", "Напред", "Next month"))
        }
        .padding(.horizontal, 12)
        .foregroundStyle(Palette.accent)
    }

    private func row(_ day: LunarDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.day().map(BgDate.weekdayDay) ?? day.date)
                .font(.subheadline.weight(.semibold))
            Text(LunarWords.dayType(day)).font(.body)
            Text(LunarWords.moon(day)).font(.caption).foregroundStyle(Palette.secondaryText)
            ForEach(LunarWords.warnings(warnings, on: day.date), id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.error)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func step(_ months: Int) {
        let next = FarmRecordAPI.farmCalendar.date(byAdding: .month, value: months, to: month) ?? month
        month = LunarAPI.month(containing: next).from
    }

    private func load() async {
        state = .loading
        let range = LunarAPI.month(containing: month)
        // The farm's warnings beside the Moon, the same window. A failed
        // read leaves them unknown, never "none".
        async let signals: LunarWarnings? = FarmPath.openSlug == nil ? nil
            : try? AgroSignalsAPI.load(from: range.from, to: range.to)
        do {
            let days = try await LunarAPI.load(from: range.from, to: range.to)
            warnings = await signals ?? LunarWarnings()
            state = .loaded(days, .fresh)
        } catch {
            _ = await signals
            state = .failed(UserMessage.text(for: error))
        }
    }
}

/// One day: its type and Moon, then the tradition's advice per crop group.
struct LunarDayView: View {
    let day: LunarDay
    /// The day's warnings, worded; empty for none or past the forecast.
    let warnings: [String]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LunarWords.dayType(day)).font(.headline)
                    Text(LunarWords.moon(day)).font(.subheadline).foregroundStyle(Palette.secondaryText)
                }
                ForEach(warnings, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Palette.error)
                }
            }
            .pageRow()
            ForEach(LunarWords.Group.allCases, id: \.self) { group in
                Section {
                    let advice = LunarWords.advice(day, group, warned: !warnings.isEmpty)
                    if advice.isEmpty {
                        Text(LunarWords.nothing).font(.footnote).foregroundStyle(Palette.secondaryText)
                    } else {
                        ForEach(advice, id: \.self) { line in
                            if line.struck {
                                Text(line.text)
                                    .strikethrough()
                                    .foregroundStyle(Palette.secondaryText)
                                    .accessibilityLabel("\(line.text) \(LunarWords.struckSpoken)")
                            } else {
                                Text(line.text)
                            }
                        }
                    }
                } header: {
                    SectionHeader(group.title)
                }
                .pageRow()
            }
            Section {} footer: {
                SectionFooter { Text(LunarWords.traditionNotice) }
            }
        }
        .pageBackground()
        .inlineTitle(day.day().map(BgDate.weekdayDay) ?? day.date)
    }
}
