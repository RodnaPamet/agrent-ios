import Foundation
import Observation

// The STATE of exchange messaging (agrent-ios#114): the inbox, one
// conversation, the unread badge, and the listing's «message the other
// party». The rules they apply live in `ExchangeMessaging.swift` and in
// `MessagingPolicy` below, so a test can hold each one without a network.
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

enum MessagingPolicy {
    /// The web's own cadences, kept: 5 s for an open conversation, 30 s for
    /// the inbox. Polls run ONLY while the screen is on screen and the app
    /// is active — the loop is a `.task` keyed on the scene phase, so leaving
    /// the screen or locking the phone cancels it.
    static let conversationInterval: Duration = .seconds(5)
    static let inboxInterval: Duration = .seconds(30)

    /// How long a poller waits before its next request.
    ///
    /// The interval, unless the last request was a 429 — then the server's
    /// `Retry-After` (through `RateLimitGate.wait`, so its floor and its
    /// fallback are the app's one rule), and never LESS than the interval: a
    /// one-second `Retry-After` is not an invitation to poll the inbox
    /// thirty times faster than it would have.
    ///
    /// A poll's 429 is NOT absorbed into `RateLimitPause.messages`. Reads are
    /// limited by the edge's read tier, per (tenant, address, user); sends
    /// draw on the farm's message budget. A throttled poll says nothing
    /// about whether a message may be sent.
    static func nextPoll(after error: Error?, interval: Duration) -> Duration {
        guard let error, let wait = RateLimitGate.wait(for: error) else { return interval }
        return max(wait, interval)
    }

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

    /// Whether Send is live.
    ///
    /// NOT the removed inquiry composer's `canSend`, which was `phase == .editing` and never
    /// comes back after a failure. Here a failed send stays sendable — that
    /// is the whole point of keeping its key — and what disables Send is only:
    /// nothing to send (blank, or over the server's limit), a send already in
    /// flight, the farm's message budget paused by a 429, or a block that
    /// the server has already said refuses this farm.
    static func canSend(draft: String, sending: Bool, paused: Bool, refusedByBlock: Bool) -> Bool {
        guard !sending, !paused, !refusedByBlock else { return false }
        if case .sendable = MessageBody.validate(draft) { return true }
        return false
    }

    /// A block refuses the INQUIRER only. The listing owner who set it can
    /// still write — and so can a role this build does not know, whom the
    /// server is left to answer.
    static func refusedByBlock(role: ExchangeThreadRole, blocked: Bool) -> Bool {
        blocked && role == .inquirer
    }

    /// What stays in the field after a 201.
    ///
    /// Empty, if what is there is still what was sent. If the farmer kept
    /// typing while the send was in flight, what is there now is a NEW
    /// message and it stays — the web clears it along with the sent one.
    static func draftAfterDelivery(_ draft: String, sent: String) -> String {
        if case .sendable(let now) = MessageBody.validate(draft), now == sent { return "" }
        if case .empty = MessageBody.validate(draft) { return "" }
        return draft
    }

    /// The counter under the composer, near the limit only.
    static func counter(for draft: String) -> (text: String, spoken: String, over: Bool)? {
        guard MessageBody.showsCounter(draft) else { return nil }
        let length = MessageBody.length(of: draft)
        let limit = MessageBody.maxLength
        return ("\(length) / \(limit)", "\(length) от \(limit) знака", length > limit)
    }

    /// The notice at the end of a blocked conversation (after the newest
    /// message since agrent-ios#124), by who is reading it.
    ///
    /// SIDE-NEUTRAL, where the web says «купувач» and «продавач»: the payload
    /// carries no listing side, and on a BUY listing the owner is the one
    /// buying.
    ///
    /// ── What a block IS today, said without "you blocked this farm" ──
    ///
    /// Conversations became private to people in #1323, but the block did not
    /// move with them: it is still stored once per pair of FARMS (the
    /// person-level block is agri-saas #1314, not done). So the listing
    /// farm's block refuses every person at the other farm, on every listing
    /// the listing farm has — including listings a colleague created, and
    /// whoever at the listing farm pressed it. The owner's side is told that
    /// scope, because nothing else on this screen says it, and it is said as
    /// what happens rather than as «блокирахте това стопанство»: in a
    /// conversation between people, "this farm" reads as "this person", and
    /// the sentence would turn false the day #1314 lands. The other side's
    /// wording is true under either rule.
    static func blockedNotice(role: ExchangeThreadRole) -> String {
        switch role {
        case .seller:
            "Съобщенията от другата страна са спрени — от всички хора в нейното стопанство, "
                + "по всички обяви на Вашето стопанство."
        case .inquirer:
            "Собственикът на обявата не приема съобщения от Вас."
        case .unknown:
            "Съобщенията в този разговор са спрени."
        }
    }

    /// The block confirmation's body. The SCOPE is the point of confirming —
    /// see `blockedNotice` for why it is said this way and not as a farm.
    static let blockConfirmation = "Блокирането спира съобщенията от всички хора в другото "
        + "стопанство, по всички обяви на Вашето стопанство — не само в този разговор. "
        + "Може да го отмените по всяко време."

    /// Whether a failed send may in fact have been delivered.
    ///
    /// A timeout or a dropped connection after the request left says nothing
    /// about whether the server stored it, and neither does a gateway's 5xx.
    /// Every other failure is an answer from before the row was written.
    static func outcomeUnknown(_ error: Error) -> Bool {
        if let url = error as? URLError {
            return url.code == .timedOut || url.code == .networkConnectionLost
        }
        if case APIClient.APIError.http(let status, _, _, _, _) = error {
            return status >= 500
        }
        return false
    }

    /// The line under the composer after a send failed.
    ///
    /// When the outcome is unknown it says so, and says that pressing Send
    /// again is safe — which it is, because the retry carries the same
    /// `Idempotency-Key` and a stored message comes back `replayed`. «Не е
    /// изпратено» there would be a claim the app cannot support.
    static func sendFailure(for error: Error) -> String {
        if outcomeUnknown(error) {
            return "Не е ясно дали съобщението е изпратено. Изпратете го отново — "
                + "няма да бъде получено два пъти."
        }
        return "Съобщението не е изпратено. \(UserMessage.text(for: error))"
    }

    /// What failed, then why — «Разговорът не може да бъде затворен. Няма
    /// интернет връзка.» The web shows only the first half.
    static func failure(_ what: String, _ error: Error) -> String {
        "\(what) \(UserMessage.text(for: error))"
    }
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
        let farm = Config.tenantSlug
        guard refreshingFarm != farm else { return }
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
    func apply(_ threads: [ExchangeThreadSummary], asOf epoch: Int, farm: String) {
        guard SessionEpoch.isCurrent(epoch), farm == Config.tenantSlug else { return }
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
            let wait = MessagingPolicy.nextPoll(after: error, interval: MessagingPolicy.inboxInterval)
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
        let farm = Config.tenantSlug
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

/// One conversation: its pages, its composer, its actions.
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

    /// The newest page's header — role, commodity, `closed`, `blocked` —
    /// as last read. Messages are in `conversation`, merged across pages.
    private(set) var header: ExchangeThread?
    private(set) var conversation: Conversation?

    /// Only before anything has loaded. A failed POLL keeps the conversation
    /// on screen: one missed request must not blank what the farmer is
    /// reading, which is what the web does.
    private(set) var loadFailure: String?

    /// The server answered 404: this conversation is not available to this
    /// PERSON (`ConversationAvailability`). Final for this screen — the
    /// messages already shown are cleared, polling stops, and the screen says
    /// so instead of offering a retry.
    ///
    /// Cleared rather than kept on screen: a 404 mid-conversation means the
    /// person has left its audience (a role changed at the farm), and the
    /// server has just said they may not read it.
    private(set) var unavailable = false

    /// Local copies of the header's two states, so a close or a block shows
    /// the moment its 200 arrives rather than after the refetch.
    private(set) var closed = false
    private(set) var blocked = false

    var draft = ""
    private(set) var sending = false
    private(set) var sendFailure: String?

    /// The outcome of the person's own send, for the screen to play. Only
    /// `send()` changes it: a poll, the refetch after a write, mark-read and
    /// the other writes never do. See `WriteFeedback`.
    private(set) var sendFeedback = WriteFeedback()

    /// Close, block, unblock, retract — one at a time.
    private(set) var acting = false
    private(set) var actionFailure: String?

    private(set) var loadingOlder = false
    private(set) var olderFailure: String?

    @ObservationIgnored private var sendKeys = MessageSendKeys()
    @ObservationIgnored private var readMarking = ReadMarking()

    /// On screen and the app active: a `run()` is going. A refetch that
    /// lands after the screen has gone marks nothing — nobody read it.
    ///
    /// A COUNT, not a flag. The screen's task restarts when the app goes
    /// inactive and back, and a cancelled loop can still be unwinding — its
    /// request finishing its cancellation — when the new one has started. A
    /// flag cleared by the old loop's `defer` would say "not visible" under
    /// a loop that is.
    @ObservationIgnored private var runningLoops = 0
    private var isVisible: Bool { runningLoops > 0 }

    init(threadID: String) {
        self.threadID = threadID
    }

    var role: ExchangeThreadRole { header?.role ?? .unknown }

    var messages: [ExchangeMessage] { conversation?.messages ?? [] }

    var refusedByBlock: Bool { MessagingPolicy.refusedByBlock(role: role, blocked: blocked) }

    var canSend: Bool {
        MessagingPolicy.canSend(
            draft: draft, sending: sending,
            paused: RateLimitPause.messages.isPaused, refusedByBlock: refusedByBlock
        )
    }

    // MARK: Reading

    /// Load, then poll every `conversationInterval`, until cancelled.
    func run() async {
        runningLoops += 1
        defer { runningLoops -= 1 }
        while !Task.isCancelled, !unavailable {
            let error = await refresh()
            // Nothing to poll for: a 404 is not one a retry changes.
            if unavailable { return }
            let wait = MessagingPolicy.nextPoll(
                after: error, interval: MessagingPolicy.conversationInterval
            )
            do { try await Task.sleep(for: wait) } catch { return }
        }
    }

    /// The newest page, merged into what is loaded — the first load, a poll,
    /// or the refetch after a write. Returns the failure for the poller.
    @discardableResult
    func refresh() async -> Error? {
        let page: ExchangeThread
        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.threadPath(threadID))
            page = try await ExchangeAPI.decodeThread(from: data)
        } catch {
            if Task.isCancelled { return nil }
            if ConversationAvailability.isUnavailable(error) {
                becomeUnavailable()
            } else if conversation == nil {
                loadFailure = UserMessage.text(for: error)
            }
            return error
        }

        header = page
        closed = page.closed
        blocked = page.blocked
        loadFailure = nil

        let shouldMark: Bool
        if var current = conversation {
            let arrival = current.mergeNewest(page)
            conversation = current
            shouldMark = readMarking.shouldMark(after: arrival, visible: isVisible)
        } else {
            conversation = Conversation(page)
            shouldMark = readMarking.shouldMarkAfterFirstLoad(visible: isVisible)
        }
        if shouldMark { await markRead() }
        return nil
    }

    /// See `unavailable`. The thread leaves the badge too: it is not in this
    /// person's inbox, and the next inbox load would drop it anyway.
    private func becomeUnavailable() {
        unavailable = true
        conversation = nil
        header = nil
        loadFailure = nil
        sendFailure = nil
        actionFailure = nil
        olderFailure = nil
        ExchangeUnreadStore.shared.markedRead(threadID)
    }

    /// A WRITE answered 404 — the send's or an action's `THREAD_NOT_FOUND`.
    /// The newest page is the authority on whether the conversation is still
    /// there, so it is asked; true when it is not, and the screen has already
    /// changed to say so.
    private func confirmedUnavailable(after error: Error) async -> Bool {
        guard ConversationAvailability.isUnavailable(error) else { return false }
        await refresh()
        return unavailable
    }

    /// `POST …/read`, and the interim race rule after it.
    ///
    /// FAILURES ARE SWALLOWED. The seam answers 501, and a mark that did not
    /// land is nothing a farmer can act on; the next message from the other
    /// party marks again. A success lowers the badge at once.
    ///
    /// The refetch the rule asks for can itself bring a message from the
    /// other farm and so mark again — bounded, because each round needs a
    /// message that was not there before.
    private func markRead() async {
        let read: ExchangeThreadRead
        do {
            read = try await ExchangeAPI.markRead(threadID: threadID)
        } catch {
            return
        }
        ExchangeUnreadStore.shared.markedRead(threadID)
        if ReadMarking.needsRefetch(readAt: read.readAt, newestShown: conversation?.newest?.createdAt) {
            await refresh()
        }
    }

    /// «Зареди по-стари съобщения». Not retried, not cached; a failure sits
    /// beside the messages already shown, never in place of them.
    func loadOlder() async {
        guard let cursor = conversation?.olderCursor, conversation?.canLoadOlder == true,
              !loadingOlder
        else { return }
        loadingOlder = true
        olderFailure = nil
        defer { loadingOlder = false }
        do {
            let data = try await APIClient.shared.data(
                for: ExchangeAPI.threadPath(threadID, before: cursor)
            )
            let page = try await ExchangeAPI.decodeThread(from: data)
            conversation?.mergeOlder(page)
        } catch {
            if Task.isCancelled { return }
            if ConversationAvailability.isUnavailable(error) {
                becomeUnavailable()
                return
            }
            olderFailure = MessagingPolicy.failure("По-старите съобщения не могат да бъдат заредени.", error)
        }
    }

    // MARK: Writing — every one NOT FIRED against production

    /// Send the draft.
    ///
    /// The key comes from `MessageSendKeys`: the same one for every retry of
    /// the same text, a new one when the text changes, dropped on any 201 —
    /// a replay included. The draft stays until the 201; there is no
    /// optimistic bubble, because the server sanitises and the 201 carries no
    /// body, so the message appears when the refetch brings the stored text.
    ///
    /// A 429 goes to `RateLimitPause.messages` — the FARM's budget, shared by
    /// every colleague and thread — and the composer says when from the pause
    /// itself. Nothing sends automatically when it reopens: a message is a
    /// person's act, not the app's.
    ///
    /// The key lives as long as this screen. A send whose response was lost,
    /// followed by leaving the conversation and coming back, mints a new key
    /// on the next tap — the one case this cannot replay.
    func send() async {
        guard case .sendable(let text) = MessageBody.validate(draft), !sending,
              !RateLimitPause.messages.isPaused
        else { return }
        let key = sendKeys.key(threadID: threadID, text: text)
        sending = true
        sendFailure = nil
        defer { sending = false }
        do {
            let sent = try await ExchangeAPI.sendMessage(
                threadID: threadID, text: text, idempotencyKey: key
            )
            sendKeys.delivered()
            draft = MessagingPolicy.draftAfterDelivery(draft, sent: text)
            if sent.reopened { closed = false }
            sendFeedback.saved()
            await refresh()
        } catch {
            // A 429 is a refusal too: the message did not go, and the
            // composer now says when it can.
            sendFeedback.refused()
            if RateLimitPause.messages.absorb(error) { return }
            if await confirmedUnavailable(after: error) { return }
            sendFailure = MessagingPolicy.sendFailure(for: error)
        }
    }

    /// Either party, no confirmation: the next message from either side
    /// reopens it, so it is not a thing that needs undoing.
    func close() async {
        await act("Разговорът не може да бъде затворен.") {
            _ = try await ExchangeAPI.closeThread(threadID: self.threadID)
            self.closed = true
        }
    }

    /// The listing owner only; confirmed on screen before `block`, because it
    /// covers every listing between the two farms. Other conversations with
    /// that farm pick it up when they are next read, and the inbox — which
    /// carries no blocked flag — reloads whenever it reappears.
    func setBlocked(_ block: Bool) async {
        await act("Промяната не може да бъде извършена.") {
            if block {
                _ = try await ExchangeAPI.blockParty(threadID: self.threadID)
            } else {
                _ = try await ExchangeAPI.unblockParty(threadID: self.threadID)
            }
            self.blocked = block
        }
    }

    /// Irreversible from here; confirmed on screen first. The web shows its
    /// SEND failure when a retract fails; this says what failed.
    func retract(_ message: ExchangeMessage) async {
        guard message.mayRetract else { return }
        await act("Съобщението не може да бъде премахнато.") {
            _ = try await ExchangeAPI.retractMessage(messageID: message.id)
            self.conversation?.tombstone(message.id)
        }
    }

    private func act(_ what: String, _ write: () async throws -> Void) async {
        guard !acting else { return }
        acting = true
        actionFailure = nil
        defer { acting = false }
        do {
            try await write()
        } catch {
            if await confirmedUnavailable(after: error) { return }
            actionFailure = MessagingPolicy.failure(what, error)
            return
        }
        await refresh()
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
            failure = MessagingPolicy.failure("Разговорът не може да бъде отворен.", error)
            return nil
        }
    }
}

/// Where `.navigationDestination(item:)` goes once a thread is open.
struct ConversationRoute: Hashable, Identifiable {
    let threadID: String
    var id: String { threadID }
}
