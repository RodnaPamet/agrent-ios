import SwiftUI

/// Every screen a tab pushes, as a value (agrent-ios#194, P4.5).
///
/// ── Why a value and not the view ──
///
/// `NavigationLink { SomeView() }` pushes a view the stack knows nothing
/// about: nothing can ask what is pushed, show something, or empty the stack
/// except the back button. A route is data, so a tab's path in `AppRouter` IS
/// the record of what is pushed. That is what lets a re-tap pop a tab to its
/// root now, and what a link (#206) or a notification (P7.7) will go through
/// later, by `AppRouter.open(_:)`.
///
/// ── Why the cases carry the model, not an id ──
///
/// Every push today starts from a row that already holds the model, and each
/// screen draws from it at once. An id would make all of them fetch what the
/// row already had. A link carries only an id; #206 adds those cases, and the
/// screens that load by one, once the server serves the links.
///
/// ── Hashed by identity ──
///
/// Three of the models are `Equatable` but not `Hashable`, and their payloads
/// — geometry, prices, notes — have no business in a hash. `hash(into:)`
/// takes the case and the id; `==` stays the synthesised full comparison, so
/// equal routes still hash alike, which is all `Hashable` asks.
enum AppRoute: Hashable, Sendable {
    case journalEntry(LogEntry)
    case listing(ExchangeListing)
    case conversation(threadID: String, commodity: String?)
    case task(WorkItemSummary)
    case location(Location)
    /// The name rides along so the header isn't blank while the archive
    /// loads — see `ParcelHistoryView.parcelName`.
    case parcelHistory(parcelID: String, parcelName: String)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .journalEntry(let entry): hasher.combine("journalEntry"); hasher.combine(entry.id)
        case .listing(let listing): hasher.combine("listing"); hasher.combine(listing.id)
        case .conversation(let threadID, _): hasher.combine("conversation"); hasher.combine(threadID)
        case .task(let summary): hasher.combine("task"); hasher.combine(summary.id)
        case .location(let location): hasher.combine("location"); hasher.combine(location.id)
        case .parcelHistory(let parcelID, _): hasher.combine("parcelHistory"); hasher.combine(parcelID)
        }
    }

    /// The tab this screen belongs to: where `AppRouter.open(_:)` shows it
    /// when that tab is on the bar.
    var home: AppSurface {
        switch self {
        case .journalEntry: .journal
        case .listing, .conversation: .exchange
        case .task: .tasks
        case .location: .locations
        case .parcelHistory: .farmRisk
        }
    }

    /// The screen. The ONE place a route becomes a view: `RoutedStack`
    /// registers it once, at the root of every stack that can hold a route.
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .journalEntry(let entry): JournalDetailView(entry: entry)
        case .listing(let listing): ListingDetailView(listing: listing)
        case .conversation(let threadID, let commodity):
            ConversationView(threadID: threadID, commodity: commodity)
        case .task(let summary): TaskDetailView(summary: summary)
        case .location(let location): ParcelMapView(location: location)
        case .parcelHistory(let parcelID, let parcelName):
            ParcelHistoryView(parcelID: parcelID, parcelName: parcelName)
        }
    }
}
