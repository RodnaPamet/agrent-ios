import SwiftUI

struct JournalListView: View {
    @State private var store = JournalStore()
    @State private var composing = false

    var body: some View {
        NavigationStack {
            // БОРСА'S SHAPE, which the owner made canonical: the list is
            // the only thing in the stack, and the title is a real
            // navigation title rather than a block drawn inside the page.
            //
            // Two previous attempts put chrome above the list — first a
            // `safeAreaInset`, then a VStack — and both still dragged the
            // title on the pull. Борса has neither, and Борса is the one
            // screen whose refresh has ever behaved. So the chrome is gone
            // rather than rearranged for a third time.
            //
            // WHAT THIS COSTS: a large navigation title truncates at
            // accessibility text sizes and cannot be told not to, which is
            // why the in-content header existed — «Земеделски дневник»
            // rendered as «Земеделски…» at accessibility3. That was a real
            // finding and this overrides it knowingly, on the owner's
            // instruction, because a refresh gesture that misbehaves on
            // every screen costs more than a title that truncates on one
            // text size.
            content
                .background(Palette.Surface.page)
                .safeAreaInset(edge: .bottom, spacing: 0) { newEntryButton }
            .navigationTitle("Земеделски дневник")
            .appMenu()
            .sheet(isPresented: $composing) {
                NewEntryView(store: store)
            }
            .task { if store.state.value == nil { await store.load() } }
        }
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
                // THE COUNT MOVED HERE from the in-content header, which
                // went with Борса's shape. It is a section header, so it
                // scrolls with the rows and cannot be dragged the way a
                // title block could.
                //
                // "Показани N" once there is more, because "N записа" is a
                // claim about the tenant's whole history that one page
                // cannot make. The old copy said exactly that and was wrong
                // for any farm past fifty entries.
                Section(store.hasMore
                        ? "Показани " + Plural.bg(entries.count, "запис", "записа")
                        : Plural.bg(entries.count, "запис", "записа")) {
                ForEach(entries) { entry in
                    NavigationLink {
                        JournalDetailView(entry: entry)
                    } label: {
                        JournalRow(entry: entry)
                    }
                    .pageRow()
                }
                loadMoreRow
                    .pageRow()
                }
            }
            .listStyle(.plain)
            .pageBackground()
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
                        Text("Зареждане…").font(.footnote).foregroundStyle(Palette.secondaryText)
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

            AdaptiveRow { chip; dateAndStatus }
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
        MetaRow {
            Text(BgDate.dayMonth(entry.occurredAt))
            if entry.status == .planned {
                MetaSeparator()
                Text(entry.status.label)
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}
