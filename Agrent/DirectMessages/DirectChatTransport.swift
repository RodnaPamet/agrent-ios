import Foundation

/// ChatKit's transport for a personal conversation (#593): the same engine
/// as Борса's threads — pages, poll, send, mark read — over `/api/social/`.
///
/// `me` is the signed-in person's id, taken once: the server names senders by
/// id only, so «mine» is worked out here. Unknown, nothing is mine, which
/// shows every bubble on the other side rather than claiming one.
struct DirectChatTransport: ChatTransport {
    let conversationID: String
    let me: String?

    func newest() async throws -> DirectConversation {
        try await DirectMessagesAPI.decodeConversation(
            APIClient.shared.data(for: DirectMessagesAPI.conversationPath(conversationID)), me: me)
    }

    func older(before cursor: String) async throws -> DirectConversation {
        try await DirectMessagesAPI.decodeConversation(
            APIClient.shared.data(for: DirectMessagesAPI.conversationPath(conversationID, before: cursor)), me: me)
    }

    /// NOT FIRED against production — see `ChatEngine.send`.
    func send(text: String, idempotencyKey: MessageSendKey) async throws -> DirectSent {
        try await DirectMessagesAPI.send(conversationID, text: text, key: idempotencyKey)
    }

    /// Not offered in the first version (owner, 2026-11-13): the screen shows
    /// no «Премахни». Wired all the same, since the route exists.
    func retract(messageID: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(DirectMessagesAPI.messagePath(messageID))
    }

    /// The server answers 204 with no instant, so the instant sent is the one
    /// returned.
    ///
    /// It is the newest message SHOWN, by the server's clock — never the
    /// phone's now (#675). The server keeps the cursor forward-only and
    /// compares it with each message's server timestamp, so a phone clock
    /// ahead stamped a cursor in the future: every later message read as
    /// already read, on every device, with no later mark able to undo it. A
    /// clock behind left the conversation unread right after it was read.
    /// Marking up to what was on screen is also the honest claim.
    func markRead(newestShown: Date?) async throws -> Date {
        let at = newestShown ?? Date()
        try await DirectMessagesAPI.markRead(conversationID, at: at)
        return at
    }

    /// A 404 is the server's one answer for "not yours, blocked, declined or
    /// gone", identical by design — `ConversationAvailability`.
    func isUnavailable(_ error: Error) -> Bool {
        ConversationAvailability.isUnavailable(error)
    }
}
