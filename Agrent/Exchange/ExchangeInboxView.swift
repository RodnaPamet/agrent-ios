import SwiftUI

/// «Съобщения», Борса's fourth section: the person's OWN conversations —
/// since agri-saas #1323 not the farm's shared inbox — newest first, as the
/// server orders them (PARITY GAP 7).
///
/// Network-only — see `ExchangeInboxStore` — and polled every 30 s while on
/// screen with the app active, as the web polls. Pull to refresh as well,
/// which the web does not have; every other list in this app does.
struct ExchangeInboxView: View {
    let store: ExchangeInboxStore
    /// Takes the farmer to «Обяви». A conversation can only START from a
    /// listing — the inbox lists the ones that exist — so an empty inbox
    /// that only says so leaves the farmer nowhere to go. The owner could
    /// not find where to write from (2026-10-01); this is the answer, on
    /// the screen where the question is asked.
    var showListings: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // A container that outlives the switch below, so the first load
        // landing does not restart the polling task.
        VStack(spacing: 0) {
            content
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await store.run()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState(
                "Няма разговори",
                icon: "bubble.left.and.bubble.right",
                message: "Разговор започва от обява на друго стопанство: отворете я и "
                    + "натиснете «Съобщение до продавача»."
            ) {
                Button("Към обявите") { showListings() }
                    .prominentButton()
                    .accessibilityInputLabels(A11y.spokenNames("Към обявите", "Listings"))
            }

        case .loaded(let rows, _):
            // Computed once per page, not per row: several rows on one
            // listing are several people since #1323 (`ExchangeInbox.siblings`).
            let siblings = ExchangeInbox.siblings(rows)
            List {
                Section {
                    ForEach(rows) { thread in
                        NavigationLink {
                            ConversationView(threadID: thread.id, commodity: thread.commodity)
                        } label: {
                            InboxRow(thread: thread, siblings: siblings[thread.id])
                        }
                    }
                }
                .pageRow()
            }
            .refreshable { await PullToRefresh.bounded { await store.load() } }
            .pageBackground()
        }
    }
}

/// One conversation in the inbox.
///
/// The web's row with its localisation defects left out: the commodity
/// through `CommodityName` (the web prints the slug), the region in
/// Bulgarian (the web prints the stored English), «т» (the web a Latin «t»),
/// and the time through `BgDate` in the phone's zone (the web: en-GB, UTC).
/// The role marker is side-neutral — «Наша обява», not «Вие продавате»,
/// which is false on every BUY listing — and farm-level, because «Вие» is
/// the person since #1323 (`ExchangeThreadRole.label`).
///
/// A row that shares its listing with others says so (`siblings`): since
/// #1323 those are separate conversations with different people, and the
/// row carries nothing else that tells them apart.
struct InboxRow: View {
    let thread: ExchangeThreadSummary
    /// How many rows in the inbox are on this listing, this one included;
    /// nil when it is the only one.
    var siblings: Int? = nil

    private var name: String { CommodityName.canonical(thread.commodity) ?? thread.commodity }
    private var region: String? { BulgarianRegion.name(english: thread.listingRegionName) }
    private var tonnes: String? { Exchange.tonnes(thread.listingQuantityTonnes) }
    private var seller: String? { thread.sellerDisplayName?.recorded }
    private var time: String { BgDate.messageTime(thread.lastMessageAt) }
    private var siblingNote: String? { siblings.map(ExchangeInbox.siblingNote) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(name).font(.headline)
                if thread.hasUnread {
                    CategoryChip(
                        text: "Ново",
                        foreground: Palette.Chip.activityText,
                        background: Palette.Chip.activityFill
                    )
                }
                // Nothing for a role this build does not know: a «—» chip
                // is a claim about the row that says nothing.
                if thread.role != .unknown {
                    CategoryChip(
                        text: thread.role.label,
                        foreground: Palette.Chip.neutralText,
                        background: Palette.Chip.neutralFill
                    )
                }
                // A word, not the web's whole sentence in a badge. Closed is
                // a state: neutral, never red.
                if thread.closed {
                    CategoryChip(
                        text: "Затворен",
                        foreground: Palette.Chip.neutralText,
                        background: Palette.Chip.neutralFill
                    )
                }
            }
            MetaRow {
                if let region { Text(region) }
                if region != nil, tonnes != nil { MetaSeparator() }
                if let tonnes { Text("\(tonnes) т") }
                if let seller {
                    if region != nil || tonnes != nil { MetaSeparator() }
                    Text(seller)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            // Its own line, not one more fact in the meta row: it is the one
            // thing that says two otherwise identical rows are two people.
            if let siblingNote {
                Label(siblingNote, systemImage: "person.2")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(time)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, 2)
        // ONE stop, spoken from the values, «Ново» early so a screen-reader
        // user scanning the list hears it before the details. Voice Control
        // gets the crop — what is printed largest — in both languages.
        .accessibleRow(
            spoken: A11y.sentence([
                name,
                thread.hasUnread ? "ново" : nil,
                thread.role == .unknown ? nil : thread.role.label,
                thread.closed ? "затворен" : nil,
                region,
                tonnes.map { "\($0) \(thread.quantity == 1 ? "тон" : "тона")" },
                seller,
                siblingNote,
                time,
            ]),
            saying: A11y.spokenNames(CommodityName.canonical(thread.commodity), thread.commodity)
        )
    }
}
