import SwiftUI

/// One section of a parcel's archive, in full, with its own paging.
///
/// ── Generic over the item, because the three sections share nothing else ──
///
/// A season sorts by harvest YEAR, an operation by completion instant, an
/// observation by the day somebody walked the field. There is no common
/// timeline and no common row, so what is shared is the SHAPE: a list, a
/// «Покажи по-стари» control, a spinner, and a failure that does not take the
/// rows with it. `ParcelHistoryLine` is the seam — each item type knows how to
/// become one, and this view knows nothing else about them.
///
/// ── It reads the STORE, not a copy of the section ──
///
/// The section is re-read from the live archive on every pass rather than
/// passed in as a value. A snapshot would be a second source of truth: the
/// card that pushed this list and the list itself would answer "what is the
/// newest entry" separately, and after a `refresh()` on the screen above, one
/// of the two would be stale with nothing on screen to say which.
///
/// ── No pull-to-refresh. Deliberately. ──
///
/// `refresh()` REPLACES the archive — that is its point, and the store says so
/// — which means the gesture would silently discard every older page the
/// reader had just asked for. Here, where asking for those pages is the whole
/// interaction, that is the one thing the screen must not do. Refresh belongs
/// to the summary screen.
struct ParcelHistorySectionList<Item: Identifiable & Equatable & Sendable>: View
where Item.ID == String {
    let title: String

    /// Which list a "load older" is for. Not an index — the three sections
    /// hold different types and nothing generic can dispatch between them.
    let part: ParcelHistoryStore.Part

    /// The screen above owns it; this view only reads and pages it.
    let store: ParcelHistoryStore

    let section: (ParcelHistoryStore.Archive) -> ParcelHistoryStore.Section<Item>
    let line: (Item) -> ParcelHistoryLine

    var body: some View {
        List {
            // No `else`: the archive is present because a card built from it
            // is what pushed this screen. If a reload ever emptied it while
            // this list was open, an empty list is the honest rendering —
            // there is nothing to report and nothing to retry from here.
            if let archive = store.state.value {
                let current = section(archive)

                // SERVER ORDER, NEWEST FIRST, FLAT.
                //
                // Nothing here sorts. The store never sorts and `appendOlder`
                // appends, so the array is already the order the server sent
                // and a client-side sort would interleave a newly loaded page
                // into the rows above it — after which the paging control has
                // stopped explaining itself, because what it added is no
                // longer at the bottom.
                //
                // РЕКОЛТИ in particular is FLAT rather than grouped by year
                // for that exact reason: `groupedByYear()` would insert loaded
                // seasons INTO groups already on screen. The year leads each
                // row instead, which is the part grouping was for.
                ForEach(current.items) { item in
                    row(line(item))
                        .pageRow()
                }

                // ONLY WHEN THERE IS SOMETHING TO SAY.
                //
                // `footer` returned an `EmptyView` for `.nothing` — the
                // ORDINARY case for a section that arrived whole — but it was
                // still added as a List row, inside a VStack with
                // `frame(maxWidth: .infinity)` and vertical padding. So every
                // complete section ended with a padded, full-width,
                // contentless row and its `.plain` separator: a blank row that
                // looks like data, which is the defect the house conventions
                // name outright, plus a VoiceOver stop after the last real row
                // with nothing to read.
                if ParcelHistoryPaging(current) != .nothing || current.failure != nil {
                    footer(current)
                        .pageRow()
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .inlineTitle(title)
    }

    // MARK: - A row

    @ViewBuilder
    private func row(_ line: ParcelHistoryLine) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if !line.text.isEmpty {
                Text(line.text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !line.detailText.isEmpty {
                Text(line.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)

        // One stop per row, spoken from the VALUES — never from the rendered
        // text, which carries the « · » that VoiceOver would announce as
        // "middle dot".
        //
        // A row with NOTHING recorded declares no label at all rather than an
        // empty one: a completed line can in principle arrive with no date, no
        // task title, no product and no unit, and silencing it would be worse
        // than leaving whatever it has to speak for itself.
        if line.isBlank {
            content
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.spoken)
        }
    }

    // MARK: - The end of the list

    /// The paging control, the spinner, or the sentence that says this is all
    /// of it — and any failure, beside the rows rather than instead of them.
    ///
    /// ── Why the end is stated in words ──
    ///
    /// A control that vanishes when tapped reads as a bug: the reader cannot
    /// tell "that was the end" from "that did not work". So a paging attempt
    /// that ends a section replaces the button with one line saying so.
    ///
    /// ── And why nothing at all shows when the section never had a cursor ──
    ///
    /// `exhausted` is set by what ARRIVED, so it is false for a section that
    /// came whole in the first page. No control was ever offered there, so
    /// there is nothing to explain — and the card upstairs shows that
    /// section's exact count, which says the same thing better.
    ///
    /// ── The failure is a note, not a state ──
    ///
    /// Every row already on screen is still good. Replacing them with an error
    /// view would throw away pages the reader waited for in order to report
    /// that the NEXT page did not arrive. The control stays put, so the retry
    /// is the same tap it was before.
    @ViewBuilder
    private func footer(_ current: ParcelHistoryStore.Section<Item>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch ParcelHistoryPaging(current) {
            case .nothing:
                EmptyView()

            case .spinner:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(ParcelHistoryCopy.loading)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            case .button:
                Button(ParcelHistoryCopy.loadOlder) {
                    Task { await store.loadOlder(part) }
                }
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.accent)

            case .end:
                Text(ParcelHistoryCopy.noOlder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .noneShown:
                Text(ParcelHistoryCopy.noneShown)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = current.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
