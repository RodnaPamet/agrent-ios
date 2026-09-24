import SwiftUI

struct JournalListView: View {
    @State private var store = JournalStore()
    @State private var composing = false

    var body: some View {
        NavigationStack {
            // Chrome as safe-area insets, List as the scrollable. In a
            // VStack the List is not what the navigation bar tracks, so a
            // pull-to-refresh dragged the banner and the in-content title
            // down the screen with the rows.
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let age = store.state.freshness?.ageDescription {
                            StaleBanner(age: age)
                        }
                        header
                    }
                    .background(.bar)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { newEntryButton }
            .pageBackground()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .appMenu()
            .sheet(isPresented: $composing) {
                NewEntryView(store: store)
            }
            .task { if store.state.value == nil { await store.load() } }
        }
    }

    /// The title lives in the CONTENT, not the navigation bar.
    ///
    /// A large navigation title truncates and cannot be told not to: at
    /// Dynamic Type accessibility3 "Земеделски дневник" rendered as
    /// "Земеделски…", which is the app's own name for the screen, cut off, on
    /// the screen the design document names as the acceptance test. As
    /// content it simply wraps.
    ///
    /// This also matches the reference artboard, which draws the title as a
    /// block inside the page rather than as chrome.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Земеделски дневник")
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
            if let count = store.state.value?.count {
                // "Показани N" once there is more, because "N записа"
                // would be a claim about the tenant's history that the app
                // cannot make from one page. The old copy said exactly
                // that and was wrong for any farm past fifty entries.
                Text(store.hasMore
                     ? "Показани " + Plural.bg(count, "запис", "записа")
                     : Plural.bg(count, "запис", "записа"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// The primary action is a full-width target at the bottom of the screen,
    /// not a toolbar glyph. A gloved thumb reaches the bottom of a phone; the
    /// top-right corner is the hardest place on the device to hit one-handed,
    /// and this is the action an operator performs standing in a field.
    @ViewBuilder
    private var newEntryButton: some View {
        if store.state.value != nil {
            Button {
                composing = true
            } label: {
                Text("Нов запис").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let entries, _) where entries.isEmpty:
            EmptyState(
                "Няма записи",
                icon: "book.closed",
                message: "Добавете първия запис в дневника."
            )

        case .loaded(let entries, _):
            List {
                ForEach(entries) { entry in
                    NavigationLink {
                        JournalDetailView(entry: entry)
                    } label: {
                        JournalRow(entry: entry)
                    }
                    // ON THE ROW, not on the List.
                    //
                    // `listRowBackground` looks like a List modifier and is
                    // not: applied to the List it reaches nothing inside a
                    // `ForEach`, which is why the bars went green twice
                    // over and the rows stayed black both times.
                    .listRowBackground(Palette.Surface.card)
                }
                loadMoreRow
                    .listRowBackground(Palette.Surface.card)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }

    /// PARITY GAP 6, and the reason it is a row rather than nothing.
    ///
    /// The list was capped at 50 with no cursor, so a tenant past fifty
    /// entries saw a truncated history and NOTHING ON SCREEN SAID SO. That
    /// is the worst shape a limit can take: a short list and a complete
    /// list look identical, so the operator has no way to tell which they
    /// are looking at — on the register the ДНЕВНИК PDF is generated from.
    ///
    /// Explicit, not infinite scroll. Loading on scroll would fetch pages
    /// an operator did not ask for, on a connection this app assumes is
    /// bad, and would still say nothing about whether the end had been
    /// reached. A button that disappears when there is no more is itself
    /// the answer to "is this all of it".
    @ViewBuilder
    private var loadMoreRow: some View {
        if store.hasMore {
            VStack(alignment: .leading, spacing: 6) {
                if store.loadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Зареждане…").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Покажи още") { Task { await store.loadMore() } }
                }
                if let error = store.loadMoreError {
                    // The pages already on screen are still good, so this
                    // is a note beside them rather than an error state that
                    // replaces them.
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One diary entry.
///
/// Sized for the actual reading conditions: outdoors, in sunlight, at arm's
/// length, with Dynamic Type possibly turned well up. The previous version
/// set the title at `.subheadline` and everything else at `.caption` — the
/// design review counted `.footnote` used ten times across the app and
/// `.body` not once, which is a desk application's type scale on a tool meant
/// to be used standing in a field.
///
/// So: `.headline` title, `.subheadline` supporting text, and the type as a
/// CHIP rather than one more grey word in a run of grey words — at a glance a
/// regulated input application is now distinguishable from an observation
/// without reading either.
struct JournalRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(.primary)

            // Side by side while they fit, stacked when they do not.
            //
            // At accessibility3 the fixed HStack squeezed both children until
            // the chip wrapped to three lines AND the date broke mid-word —
            // "септемвр / и". Neither is a wrap; both are a layout that has
            // run out of room and kept going. ViewThatFits picks the stacked
            // arrangement instead of forcing the horizontal one to fail.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chip; dateAndStatus }
                VStack(alignment: .leading, spacing: 6) { chip; dateAndStatus }
            }
        }
        .padding(.vertical, 6)
        // One stop per entry, spoken from the VALUES.
        //
        // `children: .combine` would read the rendered text, which includes
        // the `·` between date and status — "21 септември middle dot
        // Планирано". The separator is typography and has no business in the
        // audio channel, so the label is built from the fields instead. It
        // also lets the chip be spoken as what it MEANS ("Внасяне на
        // препарат") rather than as a decorated fragment, and lets the status
        // be named only when it is worth naming.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            entry.title,
            entry.type.label,
            BgDate.full(entry.occurredAt),
            entry.status == .planned ? entry.status.label : nil,
        ]))
    }

    private var chip: some View {
        CategoryChip(
            text: entry.type.label,
            foreground: entry.type.chipColors.foreground,
            background: entry.type.chipColors.background
        )
    }

    private var dateAndStatus: some View {
        // fixedSize on the vertical axis lets the date take the height it
        // needs rather than being compressed into a mid-word break.
        HStack(spacing: 6) {
            Text(BgDate.dayMonth(entry.occurredAt))
            if entry.status == .planned {
                Text("·")
                Text(entry.status.label)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
