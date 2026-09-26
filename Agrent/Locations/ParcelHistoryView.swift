import SwiftUI

/// A parcel's archive: what it grew, what was applied to it, and what was
/// growing there that nobody planted.
///
/// ── Summary, then drill in ──
///
/// One compact card per section — newest entry plus a chevron — and tapping a
/// card pushes the full list. The alternative, three full lists on one screen,
/// puts the reader in a place where the answer to "what was sprayed here" is
/// an unknown distance down a scroll shared with two other timelines.
///
/// The three sections do NOT merge into one feed. A season is a YEAR, an
/// operation is an INSTANT, an observation is a DAY somebody walked the field;
/// merging them reads well on a mock and loses the only thing each is good for.
/// That is `ParcelHistoryModels`' decision and this screen keeps it.
///
/// ── Where it is reached from, and where it is deliberately not ──
///
/// From a row on Риск по парцели. NOT from `ParcelOperationSheet`, which the
/// map tap opens: that sheet is a form to RECORD an operation and the tap is
/// gated on `mayCreateOperations`, which is false for MECHANISATOR, READER and
/// AUDITOR. Putting the archive there would have buried it in a create form
/// and hidden it from the operator who sprayed the field.
///
/// ── Read-only, this pass ──
///
/// `createCropSeason`, `createWeedObservation`, `deleteCropSeason` and
/// `deleteWeedObservation` all exist and none of them is reachable from here
/// yet. Reading the archive is the half that every role can use.
struct ParcelHistoryView: View {
    /// The name as the Риск row already knew it, so the header is not blank
    /// for the length of the first request. The archive's own name wins once
    /// it arrives — the server's is authoritative if the parcel was renamed.
    private let parcelName: String

    /// ONE STORE, owned here and handed to every drill-in.
    ///
    /// The cards and the lists they open therefore read the same `Section`
    /// values, so a card cannot claim a newest entry the list it pushes does
    /// not show, and a page loaded in a list is on the card when the reader
    /// comes back.
    @State private var store: ParcelHistoryStore

    init(parcelID: String, parcelName: String) {
        self.parcelName = parcelName
        _store = State(initialValue: ParcelHistoryStore(parcelID: parcelID))
    }

    var body: some View {
        content
            .inlineTitle(ParcelHistoryCopy.screenTitle)
            // EAGERLY, HERE — and cache-first through the store, which is
            // what makes reopening this screen instant on a bad connection.
            //
            // Deliberately not in the Риск list: fetching an archive per row
            // would be one request per parcel for data nobody asked to see,
            // on a connection this app assumes is poor.
            .task {
                if store.state.value == nil { await store.load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView(ParcelHistoryCopy.loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            // `.failed` means there was nothing cached to fall back on, so
            // this is the genuinely empty-handed case — the only one that
            // gets the error treatment and a way out.
            ErrorState(message: message) { await store.load() }

        case .loaded(let archive, _):
            List {
                header(archive)
                if archive.isEmpty {
                    emptyArchive
                } else {
                    cards(archive)
                }
            }
            .listStyle(.plain)
            .pageBackground()
            // REFRESH LIVES HERE AND NOWHERE DEEPER.
            //
            // `refresh()` replaces the archive by design — stitching a fresh
            // first page onto pages read ten minutes ago produces a list with
            // a gap in the middle that nothing on screen could explain. On a
            // drill-in the same gesture would silently discard pages the
            // reader had just asked for, so the drill-ins have none.
            .refreshable { await PullToRefresh.bounded { await store.refresh() } }
        }
    }

    // MARK: - Which parcel

    /// The parcel's name, and deliberately nothing else.
    ///
    /// `ParcelHistory.ParcelRef` also carries `cropType` — the CURRENT crop,
    /// one overwritten field with no year attached to it. The server is
    /// explicit that a client must not read that as part of the archive, and
    /// on a screen whose first card is a list of crops by harvest year it
    /// would read as exactly that. So it stays off: РЕКОЛТИ is the record,
    /// and the label on the parcel is not.
    private func header(_ archive: ParcelHistoryStore.Archive) -> some View {
        Text(archive.parcel.name.recorded ?? parcelName)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .listRowSeparator(.hidden)
            .pageRow()
    }

    /// Nothing recorded at all: ONE calm line.
    ///
    /// Not three cards each saying «Няма записи», which is what a per-section
    /// empty state produces for a parcel imported yesterday — three pieces of
    /// furniture to tell the reader one thing. And not an error, either: an
    /// empty archive is an ordinary state for a new parcel.
    ///
    /// It stays a row in the List so the refresh gesture still works on it —
    /// a parcel whose first season is recorded elsewhere while this screen is
    /// open should be one pull away from showing it.
    private var emptyArchive: some View {
        Text(ParcelHistoryCopy.emptyArchive)
            .font(.body)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .pageRow()
    }

    // MARK: - The three cards

    @ViewBuilder
    private func cards(_ archive: ParcelHistoryStore.Archive) -> some View {
        cardRow(
            ParcelHistoryCard(
                title: ParcelHistoryCopy.seasons,
                section: archive.seasons,
                line: { $0.historyLine }
            )
        ) {
            ParcelHistorySectionList(
                title: ParcelHistoryCopy.seasons,
                parcelName: parcelName,
                part: .seasons,
                store: store,
                section: { $0.seasons },
                line: { $0.historyLine }
            )
        }

        cardRow(
            ParcelHistoryCard(
                title: ParcelHistoryCopy.operations,
                section: archive.operations,
                line: { $0.historyLine }
            )
        ) {
            ParcelHistorySectionList(
                title: ParcelHistoryCopy.operations,
                parcelName: parcelName,
                part: .operations,
                store: store,
                section: { $0.operations },
                line: { $0.historyLine }
            )
        }

        cardRow(
            ParcelHistoryCard(
                title: ParcelHistoryCopy.weeds,
                section: archive.weeds,
                line: { $0.historyLine }
            )
        ) {
            ParcelHistorySectionList(
                title: ParcelHistoryCopy.weeds,
                parcelName: parcelName,
                part: .weeds,
                store: store,
                section: { $0.weeds },
                line: { $0.historyLine }
            )
        }
    }

    /// A card, and a push only when there is something to push to.
    ///
    /// An empty section renders the same card WITHOUT the link — so no
    /// chevron, no highlight, nothing that reads as a promise. Pushing to an
    /// empty list is the same broken promise as a disabled button.
    @ViewBuilder
    private func cardRow<Destination: View>(
        _ card: ParcelHistoryCard,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        if card.isTappable {
            NavigationLink { destination() } label: { cardBody(card) }
                .pageRow()
        } else {
            cardBody(card)
                .pageRow()
        }
    }

    private func cardBody(_ card: ParcelHistoryCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // THE COUNT, OR NOTHING AT ALL.
                //
                // Nothing is the usual case: the envelope carries no total,
                // so a count is only available for a section that arrived
                // whole. See `ParcelHistoryCard` for why « 100+ » would be a
                // claim this data cannot support, and why no footnote is
                // offered in its place.
                if let count = card.count {
                    Text(count)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }

            if let newest = card.newest {
                if !newest.text.isEmpty {
                    Text(newest.text)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !newest.detailText.isEmpty {
                    Text(newest.detailText)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(ParcelHistoryCopy.emptySection)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.vertical, 4)
        // ONE STOP PER CARD, SPOKEN FROM THE VALUES.
        //
        // `children: .combine` would read the rendered text, which carries
        // the « · » between a year and its crop — "2026 middle dot Пшеница".
        // The separator is typography and has no business in the audio
        // channel, which is the lesson `A11y` was written to hold.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(
            [card.title, card.count] + (card.newest?.parts ?? [ParcelHistoryCopy.emptySection])
        ))
    }
}
