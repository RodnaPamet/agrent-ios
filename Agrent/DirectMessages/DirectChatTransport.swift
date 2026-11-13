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
    /// returned: the cursor is forward only, so a phone clock a little ahead
    /// costs nothing a later message does not correct.
    func markRead() async throws -> Date {
        let now = Date()
        try await DirectMessagesAPI.markRead(conversationID, at: now)
        return now
    }

    /// A 404 is the server's one answer for "not yours, blocked, declined or
    /// gone", identical by design — `ConversationAvailability`.
    func isUnavailable(_ error: Error) -> Bool {
        ConversationAvailability.isUnavailable(error)
    }
}
