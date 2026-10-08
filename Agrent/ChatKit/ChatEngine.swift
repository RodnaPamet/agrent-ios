import Foundation
import Observation

/// One conversation's engine (agrent-ios#196, P4.7): its pages, its poll,
/// its composer's send, retract, and marking read — everything a chat
/// surface does that is not about its own product.
///
/// Lifted out of Борса's `ConversationStore`, which now wraps it with what
/// IS Борса's: the thread's header, close and block, the badge. A later
/// surface wraps it the same way with its own `ChatTransport`.
///
/// ── NOTHING HERE TOUCHES `ResponseCache` ──
///
/// Every read goes through the transport straight to the network and lives
/// in memory for as long as its screen does. Another person's words must not
/// outlive a lost phone, and the app's cache survives sign-out. Offline, a
/// conversation is an honest «Няма интернет връзка.», not yesterday's copy.
///
/// ── Every write is BUILT AND UNFIRED ──
///
/// Send, retract and mark-read are each seen by someone else. None has been
/// called against production from development, CI or A11yShots; under the UI
/// test seam each is answered 501, which is why a failed mark is swallowed.
@Observable
@MainActor
final class ChatEngine<Transport: ChatTransport> {
    typealias Message = Transport.Page.Message

    /// What the surface around the engine hears about. Set once, by its
    /// owner, after both exist — the owner's closures capture it, so they
    /// capture it weakly.
    struct Hooks {
        /// Every newest page, before it is merged: Борса reads its header.
        var newestPage: @MainActor (Transport.Page) -> Void = { _ in }
        /// A send's 201, before the refetch.
        var sent: @MainActor (Transport.Sent) -> Void = { _ in }
        /// A mark-read the server accepted.
        var markedRead: @MainActor () -> Void = {}
        /// The conversation turned out not to be available (`unavailable`).
        var unavailable: @MainActor () -> Void = {}
    }

    let threadID: String
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored var hooks = Hooks()

    /// The newest page as last read — the surface's header, for one that has
    /// one. Messages are in `conversation`, merged across pages.
    private(set) var latestPage: Transport.Page?
    private(set) var conversation: ChatConversation<Message>?

    /// Only before anything has loaded. A failed POLL keeps the conversation
    /// on screen: one missed request must not blank what the farmer is
    /// reading, which is what the web does.
    private(set) var loadFailure: String?

    /// The server said this conversation is not available to this PERSON
    /// (`ChatTransport.isUnavailable`). Final for this screen — the messages
    /// already shown are cleared, polling stops, and the screen says so
    /// instead of offering a retry.
    ///
    /// Cleared rather than kept on screen: mid-conversation it means the
    /// person has left its audience, and the server has just said they may
    /// not read it.
    private(set) var unavailable = false

    var draft = ""
    private(set) var sending = false
    private(set) var sendFailure: String?

    /// The outcome of the person's own send, for the screen to play. Only
    /// `send()` changes it: a poll, the refetch after a write, mark-read and
    /// the other writes never do. See `WriteFeedback`.
    private(set) var sendFeedback = WriteFeedback()

    /// Retract, and the surface's own writes through `act` — one at a time,
    /// behind one failure line.
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

    init(threadID: String, transport: Transport) {
        self.threadID = threadID
        self.transport = transport
    }

    var messages: [Message] { conversation?.messages ?? [] }

    // MARK: Reading

    /// Load, then poll every `conversationInterval`, until cancelled.
    func run() async {
        runningLoops += 1
        defer { runningLoops -= 1 }
        while !Task.isCancelled, !unavailable {
            let error = await refresh()
            // Nothing to poll for: an unavailable conversation is not one a
            // retry changes.
            if unavailable { return }
            let wait = ChatPolicy.nextPoll(after: error, interval: ChatPolicy.conversationInterval)
            do { try await Task.sleep(for: wait) } catch { return }
        }
    }

    /// The newest page, merged into what is loaded — the first load, a poll,
    /// or the refetch after a write. Returns the failure for the poller.
    @discardableResult
    func refresh() async -> Error? {
        let page: Transport.Page
        do {
            page = try await transport.newest()
        } catch {
            if Task.isCancelled { return nil }
            if transport.isUnavailable(error) {
                becomeUnavailable()
            } else if conversation == nil {
                loadFailure = UserMessage.text(for: error)
            }
            return error
        }

        latestPage = page
        hooks.newestPage(page)
        loadFailure = nil

        let shouldMark: Bool
        if var current = conversation {
            let arrival = current.mergeNewest(page)
            conversation = current
            shouldMark = readMarking.shouldMark(after: arrival, visible: isVisible)
        } else {
            conversation = ChatConversation(page)
            shouldMark = readMarking.shouldMarkAfterFirstLoad(visible: isVisible)
        }
        if shouldMark { await markRead() }
        return nil
    }

    /// See `unavailable`.
    private func becomeUnavailable() {
        unavailable = true
        conversation = nil
        latestPage = nil
        loadFailure = nil
        sendFailure = nil
        actionFailure = nil
        olderFailure = nil
        hooks.unavailable()
    }

    /// A WRITE answered "not available". The newest page is the authority on
    /// whether the conversation is still there, so it is asked; true when it
    /// is not, and the screen has already changed to say so.
    private func confirmedUnavailable(after error: Error) async -> Bool {
        guard transport.isUnavailable(error) else { return false }
        await refresh()
        return unavailable
    }

    /// Mark read, and the interim race rule after it.
    ///
    /// FAILURES ARE SWALLOWED. The seam answers 501, and a mark that did not
    /// land is nothing a farmer can act on; the next message from someone
    /// else marks again. A success is told to the surface at once — Борса
    /// lowers its badge.
    ///
    /// The refetch the rule asks for can itself bring a message from someone
    /// else and so mark again — bounded, because each round needs a message
    /// that was not there before.
    private func markRead() async {
        let readAt: Date
        do {
            readAt = try await transport.markRead()
        } catch {
            return
        }
        hooks.markedRead()
        if ReadMarking.needsRefetch(readAt: readAt, newestShown: conversation?.newest?.createdAt) {
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
            let page = try await transport.older(before: cursor)
            conversation?.mergeOlder(page)
        } catch {
            if Task.isCancelled { return }
            if transport.isUnavailable(error) {
                becomeUnavailable()
                return
            }
            olderFailure = ChatPolicy.failure("По-старите съобщения не могат да бъдат заредени.", error)
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
            let sent = try await transport.send(text: text, idempotencyKey: key)
            sendKeys.delivered()
            draft = ChatPolicy.draftAfterDelivery(draft, sent: text)
            hooks.sent(sent)
            sendFeedback.saved()
            await refresh()
        } catch {
            // A 429 is a refusal too: the message did not go, and the
            // composer now says when it can.
            sendFeedback.refused()
            if RateLimitPause.messages.absorb(error) { return }
            if await confirmedUnavailable(after: error) { return }
            sendFailure = ChatPolicy.sendFailure(for: error)
        }
    }

    /// Irreversible from here; confirmed on screen first. The web shows its
    /// SEND failure when a retract fails; this says what failed.
    func retract(_ message: Message) async {
        guard message.mayRetract else { return }
        await act("Съобщението не може да бъде премахнато.") {
            try await self.transport.retract(messageID: message.id)
            self.conversation?.tombstone(message.id)
        }
    }

    /// A write that is not a send — a retract, or one of the surface's own
    /// (Борса's close and block) — one at a time, its failure said as what
    /// failed and why, and the newest page read after it.
    func act(_ what: String, _ write: () async throws -> Void) async {
        guard !acting else { return }
        acting = true
        actionFailure = nil
        defer { acting = false }
        do {
            try await write()
        } catch {
            if await confirmedUnavailable(after: error) { return }
            actionFailure = ChatPolicy.failure(what, error)
            return
        }
        await refresh()
    }
}
