import SwiftUI

struct JournalListView: View {
    @State private var store = JournalStore()
    @State private var composing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                header
                content
                newEntryButton
            }
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
                Text("^[\(count) записа](inflect: true)")
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
            List(entries) { entry in
                NavigationLink {
                    JournalDetailView(entry: entry)
                } label: {
                    JournalRow(entry: entry)
                }
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
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
