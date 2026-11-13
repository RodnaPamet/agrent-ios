import Foundation
import Observation

/// One personal conversation (#593): ChatKit's engine, plus the request —
/// accept or decline, and the one message a request may carry.
///
/// ── NOT FIRED ──
///
/// Built, wired, and never sent. Opening this screen marks the conversation
/// read, and answering a request is final, so neither happens against
/// production from development.
@Observable
@MainActor
final class DirectConversationStore {
    let conversationID: String
    let chat: ChatEngine<DirectChatTransport>

    /// The state as last answered — the newest page, or a decision the
    /// moment its 200 lands, before the refetch.
    private(set) var answered: DirectConversation.State?

    init(conversationID: String, me: String? = CurrentUserStore.shared.user?.id) {
        self.conversationID = conversationID
        chat = ChatEngine(threadID: conversationID,
                          transport: DirectChatTransport(conversationID: conversationID, me: me))
        chat.hooks = .init(
            newestPage: { [weak self] page in self?.answered = page.state },
            markedRead: { ExchangeUnreadStore.shared.markedRead(directID: conversationID) },
            unavailable: { ExchangeUnreadStore.shared.markedRead(directID: conversationID) }
        )
    }

    var page: DirectConversation? { chat.latestPage }
    var conversation: ChatConversation<DirectMessage>? { chat.conversation }
    var messages: [DirectMessage] { chat.messages }
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

    var state: DirectConversation.State? { answered ?? page?.state }
    var awaitingMyAnswer: Bool { state == .request && page?.openedByMe == false }
    /// My request already holds its one message.
    var waitingForAnswer: Bool { state == .request && page?.openedByMe == true && messages.contains(where: \.mine) }

    /// Writing is open on an accepted conversation, and on my own request
    /// until it carries its one message. Never on a request I have not
    /// answered: accepting comes first.
    var mayCompose: Bool {
        switch state {
        case .accepted: true
        case .request: page?.openedByMe == true && !waitingForAnswer
        case .declined, nil: false
        }
    }

    var canSend: Bool {
        mayCompose && ChatPolicy.canSend(
            draft: draft, sending: sending, paused: RateLimitPause.messages.isPaused, refused: false)
    }

    func run() async { await chat.run() }

    @discardableResult
    func refresh() async -> Error? { await chat.refresh() }

    func loadOlder() async { await chat.loadOlder() }

    func send() async { await chat.send() }

    /// Final on the server: a declined request keeps its row, so the same
    /// person cannot open it again.
    func respond(accept: Bool) async {
        await chat.act(accept ? "Разговорът не можа да бъде приет." : "Разговорът не можа да бъде отказан.") {
            self.answered = try await DirectMessagesAPI.respond(self.conversationID, accept: accept)
        }
    }
}

/// «Пиши» on a farm's page: open (or find) the conversation with that farm's
/// owner, then go to it. NOT FIRED — opening creates a request the other
/// side sees.
@Observable
@MainActor
final class DirectConversationOpener {
    private(set) var opening = false
    private(set) var failure: String?

    func open(handle: String) async -> String? {
        guard !opening else { return nil }
        opening = true
        failure = nil
        defer { opening = false }
        do {
            return try await DirectMessagesAPI.open(handle: handle).conversationId
        } catch {
            failure = ChatPolicy.failure("Разговорът не може да бъде отворен.", error)
            return nil
        }
    }
}
