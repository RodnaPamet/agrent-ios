import Foundation

/// Where one conversation's pages come from and where its writes go
/// (agrent-ios#196). The engine is the same for every chat surface; the
/// server's routes are not. Борса's is `ExchangeChatTransport`.
///
/// Shaped by what Борса's server does, and nothing it does not: edit,
/// reactions, typing and the rest arrive with the surface whose API has them
/// (owner decision, 2026-10-08).
protocol ChatTransport: Sendable {
    associatedtype Page: ChatPage
    /// What a 201 answers, for the surface to read (Борса: whether the send
    /// reopened a closed thread).
    associatedtype Sent: Sendable

    /// The newest page: the first load, a poll, the refetch after a write.
    func newest() async throws -> Page

    /// The page before `cursor` (`ChatConversation.olderCursor`).
    func older(before cursor: String) async throws -> Page

    /// One send of the TRIMMED text (`MessageBody`), under the key that makes
    /// a retry of an unknown outcome safe (`MessageSendKeys`).
    func send(text: String, idempotencyKey: MessageSendKey) async throws -> Sent

    /// Retract one of my own messages.
    func retract(messageID: String) async throws

    /// Mark the conversation read; the server's `readAt`, for
    /// `ReadMarking.needsRefetch`.
    func markRead() async throws -> Date

    /// Whether a failure means this conversation is NOT AVAILABLE to this
    /// person — final, not something a retry changes. Per server: on Борса
    /// it is any 404 (`ConversationAvailability`).
    func isUnavailable(_ error: Error) -> Bool
}
