import Foundation

/// Personal messages, person to person (agri-saas P8.2, #593).
///
/// Person-scoped, under `/api/social/` rather than a farm, and switched on by
/// the server's `social.direct-messages` flag. A farm HANDLE names who to
/// write to; the server resolves it to that farm's active owner, so the phone
/// never supplies a person.
///
/// Owner, 2026-11-13: the conversations sit in «Съобщения» beside Борса's,
/// newest first, one list; the first version is text, mark read, and accept
/// or decline a request. Photos, reactions and edit/retract come later.
///
/// ── NOT FIRED ──
///
/// Opening a conversation, sending, answering a request and marking read are
/// all writes another person sees. Built, wired, and never sent from
/// development, CI or A11yShots: the owner makes the first real send.
enum DirectMessagesAPI {
    static let flag = "social.direct-messages"

    /// Only the personal rows. The server's inbox also merges Борса's
    /// threads, but the phone reads those from the farm's own inbox, which
    /// carries the listing a row needs. An unknown `source` is a 400 there,
    /// never a fallback, so this is spelled exactly.
    static let inboxPath = "/api/social/inbox?source=dm"
    static let openPath = "/api/social/conversations"

    static func conversationPath(_ id: String, before cursor: String? = nil) -> String {
        let base = "\(openPath)/\(URLEscape.segment(id))"
        guard let cursor else { return base }
        return "\(base)?before=\(URLEscape.queryValue(cursor))"
    }

    static func messagesPath(_ id: String) -> String { "\(openPath)/\(URLEscape.segment(id))/messages" }
    static func readPath(_ id: String) -> String { "\(openPath)/\(URLEscape.segment(id))/read" }
    static func respondPath(_ id: String) -> String { "\(openPath)/\(URLEscape.segment(id))/respond" }
    static func messagePath(_ messageID: String) -> String { "/api/social/messages/\(URLEscape.segment(messageID))" }

    // MARK: Reads

    static func inbox() async throws -> [DirectInboxItem] {
        try await decodeInbox(APIClient.shared.data(for: inboxPath))
    }

    /// A row this build cannot read costs that row, never the inbox.
    static func decodeInbox(_ data: Data) async throws -> [DirectInboxItem] {
        try await APIClient.shared.decode(data, as: DirectInboxPage.self).items.compactMap(\.value)
    }

    static func decodeConversation(_ data: Data, me: String?) async throws -> DirectConversation {
        try await APIClient.shared.decode(data, as: DirectConversation.Wire.self).resolved(me: me)
    }

    // MARK: Writes — NOT FIRED against production

    /// The conversation with this farm's owner, created if there is none.
    /// Idempotent on the server, and limited to five an hour.
    static func open(handle: String) async throws -> DirectOpened {
        let data = try await APIClient.shared.postReturningData(
            openPath, body: ["handle": handle], idempotencyKey: nil)
        return try await APIClient.shared.decode(data, as: DirectOpened.self)
    }

    /// The key travels in the BODY here, not a header: a repeat with it
    /// returns the first attempt's message with `deduplicated: true`.
    static func send(_ id: String, text: String, key: MessageSendKey) async throws -> DirectSent {
        let data = try await APIClient.shared.postReturningData(
            messagesPath(id), body: SendDirectMessage(body: text, idempotencyKey: key.value),
            idempotencyKey: nil)
        UsageEvents.note(.messageSent)
        return try await APIClient.shared.decode(data, as: DirectSent.self)
    }

    /// Forward only on the server, so a repeat or a slow clock is harmless.
    static func markRead(_ id: String, at instant: Date) async throws {
        _ = try await APIClient.shared.postReturningData(
            readPath(id), body: ["readAt": BgDate.isoInstant(instant)], idempotencyKey: nil)
    }

    static func respond(_ id: String, accept: Bool) async throws -> DirectConversation.State {
        let data = try await APIClient.shared.postReturningData(
            respondPath(id), body: ["decision": accept ? "ACCEPT" : "DECLINE"], idempotencyKey: nil)
        return try await APIClient.shared.decode(data, as: DirectResponded.self).state
    }
}

// MARK: - The inbox

struct DirectInboxPage: Decodable, Sendable {
    let items: [Lossy<DirectInboxItem>]
}

/// One personal conversation in the inbox.
struct DirectInboxItem: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let lastMessageAt: Date
    let unread: Bool
    /// True only on a request someone else opened and I have not answered.
    /// `false` on my own request (waiting is not owing), `null` elsewhere.
    let awaitingMyAnswer: Bool?
    /// The other side as the server names them, when it can.
    let title: String?

    private enum CodingKeys: String, CodingKey { case source, id, lastMessageAt, unread, awaitingMyAnswer, title }

    init(id: String, lastMessageAt: Date, unread: Bool, awaitingMyAnswer: Bool?, title: String?) {
        self.id = id
        self.lastMessageAt = lastMessageAt
        self.unread = unread
        self.awaitingMyAnswer = awaitingMyAnswer
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `?source=dm` asks for these only; anything else is not this row.
        guard try c.decode(String.self, forKey: .source) == "dm" else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "not a personal row")
        }
        id = try c.decode(String.self, forKey: .id)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        awaitingMyAnswer = try c.decodeIfPresent(Bool.self, forKey: .awaitingMyAnswer)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    /// What the row and the conversation's title say.
    var name: String { DirectWords.name(title) }
}

// MARK: - One conversation

/// One page of a personal conversation, with `mine` resolved against the
/// signed-in person, since the server names senders by id only.
struct DirectConversation: ChatPage, Equatable, Sendable {
    enum State: String, Decodable, Sendable {
        case request = "REQUEST"
        case accepted = "ACCEPTED"
        case declined = "DECLINED"
    }

    let id: String
    let state: State
    /// Whether I opened it — the side that waits rather than answers.
    let openedByMe: Bool
    let messages: [DirectMessage]
    let olderCursor: String?

    struct Wire: Decodable, Sendable {
        let id: String
        let state: State
        let initiatedByUserId: String
        let olderCursor: String?
        let messages: [Lossy<Message>]

        struct Message: Decodable, Sendable {
            let id: String
            let senderUserId: String
            let body: String?
            let createdAt: Date
            let deletedAt: Date?
        }

        func resolved(me: String?) -> DirectConversation {
            DirectConversation(
                id: id, state: state, openedByMe: me != nil && initiatedByUserId == me,
                messages: messages.compactMap(\.value).map {
                    DirectMessage(id: $0.id, mine: me != nil && $0.senderUserId == me,
                                  body: $0.deletedAt == nil ? $0.body : nil, createdAt: $0.createdAt)
                },
                olderCursor: olderCursor)
        }
    }

    /// The request is mine to answer.
    var awaitingMyAnswer: Bool { state == .request && !openedByMe }

    /// My request holds its one message: the server refuses a second until
    /// the other side accepts.
    var waitingForAnswer: Bool { state == .request && openedByMe && messages.contains(where: \.mine) }
}

struct DirectMessage: ChatMessage {
    let id: String
    let mine: Bool
    let body: String?
    let createdAt: Date

    /// Two people, so the other side is never a colleague.
    var speaker: MessageSpeaker { MessageSpeaker(mine: mine, fromMyFarm: false) }
    var senderName: String? { nil }
    var isTombstone: Bool { body == nil }

    func tombstoned() -> DirectMessage { DirectMessage(id: id, mine: mine, body: nil, createdAt: createdAt) }
}

// MARK: - Write bodies and answers

struct SendDirectMessage: Encodable, Equatable, Sendable {
    let body: String
    let idempotencyKey: String
}

struct DirectSent: Decodable, Sendable {
    let messageId: String
    let deduplicated: Bool?
}

struct DirectOpened: Decodable, Sendable {
    let conversationId: String
    let state: DirectConversation.State
}

struct DirectResponded: Decodable, Sendable {
    let state: DirectConversation.State
}

// MARK: - Words

enum DirectWords {
    /// The chip that tells a personal row from a listing's.
    static let kind = "Лично"
    static let awaiting = "Чака вашия отговор"

    static func name(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Лично съобщение"
        }
        return title
    }

    static let requestNote = "Това стопанство ви пише за първи път. Приемете, за да си пишете. Ако откажете, то няма да може да ви пише повече."
    static let waitingNote = "Съобщението е изпратено. Можете да пишете още, след като другата страна приеме."
    static let declinedNote = "Разговорът е отказан. Не можете да си пишете в него."
    static let firstMessageNote = "Първото съобщение е заявка. Другата страна решава дали да приеме разговора."
}
