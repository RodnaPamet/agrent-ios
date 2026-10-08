import Foundation
import Observation

// The STATE of exchange messaging (agrent-ios#114): the inbox, one
// conversation, the unread badge, and the listing's «message the other
// party». The rules they apply live in `ExchangeMessaging.swift` and in
// `MessagingPolicy` below — and, for chat itself, in ChatKit, whose
// `ChatEngine` runs the conversation (agrent-ios#196) — so a test can hold
// each one without a network.
//
// ── NOTHING HERE TOUCHES `ResponseCache` ──
//
// Every read goes straight to `APIClient.shared.data(for:)` and lives in
// memory for as long as its screen does. The web keeps `/exchange/threads`
// out of its persistent cache on purpose — another farm's words must not
// outlive a lost phone — and this app's cache survives sign-out and is keyed
// on a hard-coded tenant. Offline, a conversation is an honest «Няма интернет
// връзка.», not yesterday's copy.
//
// ── Every write here is BUILT AND UNFIRED ──
//
// Open, send, close, block, unblock and retract are each seen by another
// farm; `read` moves the person's own pointer (per person since agri-saas
// #1323 — it used to move every colleague's). None has been called against
// production from development, CI or A11yShots. Under the UI test seam each
// is answered 501, which is why a failed mark-read is swallowed.

// MARK: - The screen rules

/// Борса's own rules: who may write and where, blocks, the badge's label,
/// the inbox's cadence. Chat's rules — the poll's backoff, Send, the
/// composer, a failed send — are ChatKit's `ChatPolicy` (agrent-ios#196).
enum MessagingPolicy {
    /// The web's own cadence for the inbox, kept: 30 s (an open conversation
    /// polls on `ChatPolicy.conversationInterval`). Polls run ONLY while the
    /// screen is on screen and the app is active.
    static let inboxInterval: Duration = .seconds(30)

    /// «Съобщения (3)» for the segment, «Борса (3)» for the app menu row:
    /// the count only when there is one.
    static func counted(_ label: String, unread: Int) -> String {
        unread > 0 ? "\(label) (\(unread))" : label
    }

    /// Whether to OFFER a write — never whether one is allowed. Fails open
    /// when the user is unknown, like `FarmRiskStore.mayAsk`: the server is
    /// the authority either way and its 403 is rendered.
    static func mayWrite(_ user: CurrentUser?) -> Bool {
        user?.mayWrite ?? true
    }

    /// The listing's messaging button, named for who is on the OTHER side.
    ///
    /// The one place the side is known: a SELL listing's owner is selling,
    /// so the person tapping writes to the seller; a BUY listing's owner is
    /// buying. The web says «до продавача» on both, which is wrong on every
    /// BUY listing. An unrecognised side says neither.
    static func messagePartyLabel(side: ExchangeSide) -> (bulgarian: String, english: String) {
        switch side {
        case .sell: ("Съобщение до продавача", "Message the seller")
        case .buy: ("Съобщение до купувача", "Message the buyer")
        case .unknown: ("Съобщение по обявата", "Message about the listing")
        }
    }

    /// Whether «message the other party» belongs on a listing.
    ///
    /// NOT gated on the listing being active, deliberately and as on the web:
    /// the route applies no status rule and is idempotent, so on an expired
    /// or withdrawn listing the button is the way back to a conversation that
    /// already exists. Hidden on the farm's own listing — the server refuses
    /// `THREAD_OWN_LISTING` — and from a role that cannot write.
    static func offersMessageParty(isOwn: Bool, mayWrite: Bool) -> Bool {
        !isOwn && mayWrite
    }

    /// A block refuses the INQUIRER only. The listing owner who set it can
    /// still write — and so can a role this build does not know, whom the
    /// server is left to answer.
    static func refusedByBlock(role: ExchangeThreadRole, blocked: Bool) -> Bool {
        blocked && role == .inquirer
    }

    /// The notice at the end of a blocked conversation (after the newest
    /// message since agrent-ios#124), by who is reading it.
    ///
    /// SIDE-NEUTRAL, where the web says «купувач» and «продавач»: the payload
    /// carries no listing side, and on a BUY listing the owner is the one
    /// buying.
    ///
    /// ── What a block IS: one PERSON, on every listing of this farm ──
    ///
    /// Since agri-saas #1397 (the owner's ruling on #1314, live 2026-10-08)
    /// the block is stored per PERSON: `sellerTenantId` + `blockedUserId`,
    /// and the person is the one who STARTED this conversation
    /// (`thread.inquirerUserId`). It refuses them on every listing the
    /// listing farm has — including listings a colleague created — and NOT
    /// their colleagues, who can still start conversations of their own. The
    /// owner chose that knowing a blocked person can ask a colleague instead.
    ///
    /// Named as «човека, започнал разговора», not «другата страна»: the
    /// other farm's OWNER/ADMIN can write in this conversation too, and with
    /// names on the bubbles (#187) the seller may see two people on that
    /// side — of whom the block names one.
    ///
    /// Until #1397 it was stored per pair of FARMS and this said «от всички
    /// хора в нейното стопанство», which went false the day it deployed
    /// (agrent-ios#186). The other side's sentence speaks of THIS
    /// conversation: whoever on that side reads it — the person blocked or a
    /// colleague of theirs who also wrote here — the conversation is closed
    /// to them, and only the person blocked is refused elsewhere.
    static func blockedNotice(role: ExchangeThreadRole) -> String {
        switch role {
        case .seller:
            "Съобщенията от човека, започнал разговора, са спрени по всички обяви на Вашето стопанство."
        case .inquirer:
            "Собственикът на обявата не приема повече съобщения в този разговор."
        case .unknown:
            "Съобщенията в този разговор са спрени."
        }
    }

    /// The block confirmation's question: WHOM, which «другата страна» no
    /// longer says once two people can be on that side — see `blockedNotice`.
    static let blockTitle = "Да блокирате ли човека, започнал разговора?"

    /// The block confirmation's body. The SCOPE is the point of confirming —
    /// see `blockedNotice`. Both halves of it: more than this conversation
    /// (every listing of this farm), and less than the other farm (only this
    /// person; their colleagues can still start conversations of their own).
    static let blockConfirmation = "Блокирането спира съобщенията от човека, започнал разговора, "
        + "по всички обяви на Вашето стопанство — не само в този разговор. Другите хора от "
        + "неговото стопанство все още могат да започнат свои разговори с Вас. "
        + "Може да го отмените по всяко време."

}

// MARK: - The unread badge

/// How many conversations have something unread, for the Борса badge and the
/// inbox segment's label.
///
/// App-wide, so one singleton, as `OutboxStore` is: the tab bar, the app menu
/// and the segment all show the same number. Refreshed at launch, on every
/// return to the foreground, and whenever the inbox loads; lowered at once
/// when a conversation is marked read, rather than a request later.
///
/// Held as the SET of thread ids, not a number, so that marking one read
/// removes exactly that one — twice is harmless — and so that `hasUnread`,
/// not `unreadCount`, is what counts (see `ExchangeInbox.unreadCount`).
///
/// ── The PERSON's badge since #1323 ──
///
/// The logic is unchanged and still right; what it counts changed meaning.
/// `hasUnread` and the read pointer are per person, so: a colleague reading
/// a thread no longer clears this badge; a colleague's reply now RAISES it
/// (it used to arrive as "ours"); and the set is of the person's own inbox,
/// which `SessionReset` already empties on sign-out. A thread that turns out
/// to be unavailable (404) is dropped from it at once.
@Observable
@MainActor
final class ExchangeUnreadStore {
    static let shared = ExchangeUnreadStore()

    private(set) var unreadThreadIDs: Set<String> = []

    var count: Int { unreadThreadIDs.count }

    /// The farm a badge read is on its way for. ONE PER FARM rather than one
    /// at all: a read for the farm open a moment ago must not stop the open
    /// farm's own, or after a switch the badge would stay empty until the
    /// next return to the app.
    @ObservationIgnored private var refreshingFarm: String?

    /// The inbox's first page, read for its `hasUnread` flags.
    ///
    /// Network-only, like the inbox. A failure keeps the last known count:
    /// offline, a badge that was right an hour ago is closer to the truth
    /// than one that silently dropped to nothing.
    ///
    /// Skipped for a MECHANISATOR, who cannot see Борса and would only
    /// collect a 403 — when the user is KNOWN to be one. Unknown fails open,
    /// which costs at most one refused read.
    func refresh() async {
        guard let farm = FarmPath.openSlug, refreshingFarm != farm else { return }
        if let me = CurrentUserStore.shared.user, me.isOperator { return }
        refreshingFarm = farm
        defer { if refreshingFarm == farm { refreshingFarm = nil } }
        let epoch = SessionEpoch.current
        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.threadsPath)
            apply(try await ExchangeAPI.decodeThreads(from: data).threads, asOf: epoch, farm: farm)
        } catch {
            // Kept. See above.
        }
    }

    /// `asOf` and `farm` are REQUIRED, so no caller can apply a page without
    /// saying which session fetched it, and for which farm: a page that
    /// started under A and lands after Изход is A's farm's threads, and is
    /// dropped (`SessionEpoch`) — and so is one that started on the farm
    /// open a moment ago and lands after a switch (agrent-ios#179).
    func apply(_ threads: [ExchangeThreadSummary], asOf epoch: Int, farm: String?) {
        guard SessionEpoch.isCurrent(epoch), farm != nil, farm == FarmPath.openSlug else { return }
        unreadThreadIDs = Set(threads.filter(\.hasUnread).map(\.id))
    }

    func markedRead(_ threadID: String) {
        unreadThreadIDs.remove(threadID)
    }

    /// No badge — part of `SessionReset`. The person whose threads these were
    /// may not be the next account.
    func reset() {
        unreadThreadIDs = []
    }
}

// MARK: - The inbox

/// «Съобщения»: the person's OWN conversations, from both sides — since
/// #1323 not the farm's shared inbox, so two colleagues see different lists.
///
/// ONE PAGE — the server's default hundred — as on the web, which ignores
/// `nextCursor` too. A farm with more than a hundred live conversations is
/// not one this app has met; `ExchangeAPI.threadsPath(cursor:)` is there
/// when it does.
@Observable
@MainActor
final class ExchangeInboxStore {
    private(set) var state: LoadState<[ExchangeThreadSummary]> = .loading

    /// Poll every `inboxInterval` until cancelled — by the screen leaving or
    /// the app going inactive. The first pass is immediate, so returning to
    /// the inbox shows the conversation just read without «Ново».
    func run() async {
        while !Task.isCancelled {
            let error = await load()
            let wait = ChatPolicy.nextPoll(after: error, interval: MessagingPolicy.inboxInterval)
            do { try await Task.sleep(for: wait) } catch { return }
        }
    }

    /// Returns the failure, for the poller to read a 429 from. A failure
    /// never replaces rows already on screen — a poll that missed is not
    /// news — and a CANCELLED request is not a failure at all: it is the
    /// screen leaving, and must not be the error it finds on return.
    @discardableResult
    func load() async -> Error? {
        if state.value == nil { state = .loading }
        let epoch = SessionEpoch.current
        let farm = FarmPath.openSlug
        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.threadsPath)
            let page = try await ExchangeAPI.decodeThreads(from: data)
            state = .loaded(page.threads, .fresh)
            ExchangeUnreadStore.shared.apply(page.threads, asOf: epoch, farm: farm)
            return nil
        } catch {
            if Task.isCancelled { return nil }
            if state.value == nil { state = .failed(UserMessage.text(for: error)) }
            return error
        }
    }
}

// MARK: - One conversation

/// One conversation: ChatKit's engine, and what is Борса's around it — the
/// thread's header (role, commodity), close and block, the badge.
///
/// THE ENGINE is `chat` (agrent-ios#196): pages, poll, send, retract and
/// mark-read live there. This class keeps the face the screen already knew,
/// forwarding to it, so `ConversationView` reads one store as it always has.
///
/// ── NOT FIRED ──
///
/// Built, wired, and never sent. Writing to another farm is the owner's act,
/// the same standing decision as `createListing`. And OPENING this screen
/// against production is a write too: it marks the conversation read.
@Observable
@MainActor
final class ConversationStore {
    let threadID: String
    let chat: ChatEngine<ExchangeChatTransport>

    /// Local copies of the header's two states, so a close or a block shows
    /// the moment its 200 arrives rather than after the refetch. Every newest
    /// page sets them again.
    private(set) var closed = false
    private(set) var blocked = false

    init(threadID: String) {
        self.threadID = threadID
        chat = ChatEngine(threadID: threadID, transport: ExchangeChatTransport(threadID: threadID))
        chat.hooks = .init(
            newestPage: { [weak self] page in
                self?.closed = page.closed
                self?.blocked = page.blocked
            },
            sent: { [weak self] sent in
                if sent.reopened { self?.closed = false }
            },
            // The badge, lowered at once: a mark the server accepted, or a
            // thread that is not in this person's inbox at all (404) — the
            // next inbox load would drop it anyway.
            markedRead: { ExchangeUnreadStore.shared.markedRead(threadID) },
            unavailable: { ExchangeUnreadStore.shared.markedRead(threadID) }
        )
    }

    /// The newest page's header — role, commodity, `closed`, `blocked` — as
    /// last read.
    var header: ExchangeThread? { chat.latestPage }
    var conversation: Conversation? { chat.conversation }
    var messages: [ExchangeMessage] { chat.messages }
    var loadFailure: String? { chat.loadFailure }
    var unavailable: Bool { chat.unavailable }

    var draft: String {
        get { chat.draft }
        set { chat.draft = newValue }
    }

    var sending: Bool { chat.sending }
    var sendFailure: String? { chat.sendFailure }
    var sendFeedback: WriteFeedback { chat.sendFeedback }
    var acting: Bool { chat.acting }
    var actionFailure: String? { chat.actionFailure }
    var loadingOlder: Bool { chat.loadingOlder }
    var olderFailure: String? { chat.olderFailure }

    var role: ExchangeThreadRole { header?.role ?? .unknown }

    var refusedByBlock: Bool { MessagingPolicy.refusedByBlock(role: role, blocked: blocked) }

    var canSend: Bool {
        ChatPolicy.canSend(
            draft: draft, sending: sending,
            paused: RateLimitPause.messages.isPaused, refused: refusedByBlock
        )
    }

    // MARK: Reading and the composer — the engine's

    func run() async { await chat.run() }

    @discardableResult
    func refresh() async -> Error? { await chat.refresh() }

    func loadOlder() async { await chat.loadOlder() }

    func send() async { await chat.send() }

    func retract(_ message: ExchangeMessage) async { await chat.retract(message) }

    // MARK: Борса's own writes — every one NOT FIRED against production

    /// Either party, no confirmation: the next message from either side
    /// reopens it, so it is not a thing that needs undoing.
    func close() async {
        await chat.act("Разговорът не може да бъде затворен.") {
            _ = try await ExchangeAPI.closeThread(threadID: self.threadID)
            self.closed = true
        }
    }

    /// The listing owner only; confirmed on screen before `block`, because it
    /// covers every listing between the two farms. Other conversations with
    /// that farm pick it up when they are next read, and the inbox — which
    /// carries no blocked flag — reloads whenever it reappears.
    func setBlocked(_ block: Bool) async {
        await chat.act("Промяната не може да бъде извършена.") {
            if block {
                _ = try await ExchangeAPI.blockParty(threadID: self.threadID)
            } else {
                _ = try await ExchangeAPI.unblockParty(threadID: self.threadID)
            }
            self.blocked = block
        }
    }
}

// MARK: - From a listing

/// «Съобщение до продавача» / «до купувача»: open (or find) this farm's
/// conversation on a listing, then go to it.
///
/// ── NOT FIRED ──
///
/// Opening writes a thread the listing's owner sees at once, unread and
/// empty. Built, wired, and never tapped against production.
@Observable
@MainActor
final class ListingThreadOpener {
    private(set) var opening = false
    private(set) var failure: String?

    /// The thread's id, or nil with `failure` set.
    ///
    /// One retry on a 409: two first opens racing — a double tap on two
    /// devices — can collide on the unique (listing, inquirer PERSON) row
    /// (per farm until #1323), and the second attempt finds the thread the
    /// first one made. A colleague's thread on the same listing is not that
    /// row: since #1323 each person who writes gets their own conversation.
    func open(listingID: String) async -> String? {
        guard !opening else { return nil }
        opening = true
        failure = nil
        defer { opening = false }
        do {
            do {
                return try await ExchangeAPI.openThread(listingID: listingID).id
            } catch APIClient.APIError.conflict {
                return try await ExchangeAPI.openThread(listingID: listingID).id
            }
        } catch {
            failure = ChatPolicy.failure("Разговорът не може да бъде отворен.", error)
            return nil
        }
    }
}
