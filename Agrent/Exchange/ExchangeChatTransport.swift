import Foundation

/// Борса's routes, as ChatKit's transport (agrent-ios#196): one thread's
/// pages, its send, retract and mark-read, and what a 404 means.
///
/// Network only, like every messaging read — nothing here touches
/// `ResponseCache` (see `ChatEngine`).
struct ExchangeChatTransport: ChatTransport {
    let threadID: String

    func newest() async throws -> ExchangeThread {
        let data = try await APIClient.shared.data(for: ExchangeAPI.threadPath(threadID))
        return try await ExchangeAPI.decodeThread(from: data)
    }

    func older(before cursor: String) async throws -> ExchangeThread {
        let data = try await APIClient.shared.data(for: ExchangeAPI.threadPath(threadID, before: cursor))
        return try await ExchangeAPI.decodeThread(from: data)
    }

    /// NOT FIRED against production — see `ChatEngine.send`.
    func send(text: String, idempotencyKey: MessageSendKey) async throws -> ExchangeMessageSent {
        try await ExchangeAPI.sendMessage(threadID: threadID, text: text, idempotencyKey: idempotencyKey)
    }

    func retract(messageID: String) async throws {
        _ = try await ExchangeAPI.retractMessage(messageID: messageID)
    }

    func markRead() async throws -> Date {
        try await ExchangeAPI.markRead(threadID: threadID).readAt
    }

    /// Any 404 — `ConversationAvailability` says why the status alone decides.
    func isUnavailable(_ error: Error) -> Bool {
        ConversationAvailability.isUnavailable(error)
    }
}
