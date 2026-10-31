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
    /// A task named by id alone: a tapped notification's link (#368). Its
    /// screen reads the task first, then shows it as a row's tap would.
    case taskID(String)
    case location(Location)
    /// A block named by id alone: an agro warning's link (#475). Its screen
    /// finds the block in the farm's list first.
    case locationID(String)
    /// A listing named by id alone: a new interest or inquiry (#475).
    case listingID(String)
    /// The name rides along so the header isn't blank while the archive
    /// loads — see `ParcelHistoryView.parcelName`.
    ///
    /// `recordIn` is the parcel in its block when the history was opened from
    /// Блокове's map (#387): the history then offers «Ново мероприятие» for
    /// it, which used to be what a tap on the map opened. Nil from Риск,
    /// which has never offered it.
    case parcelHistory(parcelID: String, parcelName: String, recordIn: ParcelInBlock? = nil)
    /// «Съобщения», from Борса's bar (owner, 2026-10-24). Carries nothing: it
    /// is the person's one inbox. «Ферми» had this place until the directory
    /// moved into the board's search.
    case exchangeInbox
    /// A recorded treatment's parcels on a map (#399), read by its handle.
    case treatmentMap(handle: String, title: String)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .journalEntry(let entry): hasher.combine("journalEntry"); hasher.combine(entry.id)
        case .listing(let listing): hasher.combine("listing"); hasher.combine(listing.id)
        case .conversation(let threadID, _): hasher.combine("conversation"); hasher.combine(threadID)
        case .task(let summary): hasher.combine("task"); hasher.combine(summary.id)
        case .taskID(let id): hasher.combine("taskID"); hasher.combine(id)
        case .location(let location): hasher.combine("location"); hasher.combine(location.id)
        case .locationID(let id): hasher.combine("locationID"); hasher.combine(id)
        case .listingID(let id): hasher.combine("listingID"); hasher.combine(id)
        case .parcelHistory(let parcelID, _, _): hasher.combine("parcelHistory"); hasher.combine(parcelID)
        case .exchangeInbox: hasher.combine("exchangeInbox")
        case .treatmentMap(let handle, _): hasher.combine("treatmentMap"); hasher.combine(handle)
        }
    }

    /// The tab this screen belongs to: where `AppRouter.open(_:)` shows it
    /// when that tab is on the bar.
    var home: AppSurface {
        switch self {
        case .journalEntry, .treatmentMap: .journal
        case .listing, .listingID, .conversation, .exchangeInbox: .exchange
        case .task, .taskID: .tasks
        case .location, .locationID: .locations
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
        case .taskID(let id): TaskLinkView(id: id)
        case .location(let location): ParcelMapView(location: location)
        case .locationID(let id): LocationLinkView(id: id)
        case .listingID(let id): ListingLinkView(id: id)
        case .parcelHistory(let parcelID, let parcelName, let recordIn):
            ParcelHistoryView(parcelID: parcelID, parcelName: parcelName, recordIn: recordIn)
        case .exchangeInbox: ExchangeInboxScreen()
        case .treatmentMap(let handle, let title): TreatmentMapView(handle: handle, title: title)
        }
    }
}

extension AppRoute {
    /// The screen a tapped notification's link opens (#368).
    init(_ link: PushLink) {
        switch link {
        case .task(_, let id): self = .taskID(id)
        // The conversation reads its own commodity with the thread.
        case .thread(_, let id): self = .conversation(threadID: id, commodity: nil)
        case .location(_, let id): self = .locationID(id)
        case .listing(_, let id): self = .listingID(id)
        }
    }
}

/// A parcel and the block it is in: what «Ново мероприятие»
/// (`ParcelOperationSheet`) needs, carried on a history route (#387).
struct ParcelInBlock: Hashable, Sendable {
    let locationID: String
    let parcel: Parcel
}
