import Foundation

/// «Какво помни асистентът»'s remembered points (#507): the profile half,
/// which a person can also correct.
typealias AssistantMemoryStore = ForgettableList<AssistantMemoryAPI.Point>

/// The exchanges half (#521): the person's past conversations, which can be
/// forgotten but not corrected.
typealias PastConversationsStore = ForgettableList<AssistantMemoryAPI.Conversation>

extension ForgettableList where Item == AssistantMemoryAPI.Point {
    typealias Point = AssistantMemoryAPI.Point

    convenience init() {
        self.init(api: API(
            list: { try await AssistantMemoryAPI.list() },
            forget: { try await AssistantMemoryAPI.forget($0) },
            forgetAll: { try await AssistantMemoryAPI.forgetAll() },
            edit: { try await AssistantMemoryAPI.edit($0, text: $1) }))
    }

    var points: [Point] { items }

    /// The person's own wording. Nil on success, the sentence on a refusal.
    /// A point forgotten meanwhile (from the web, say) leaves the list with
    /// the server's sentence, as there is nothing left to correct.
    func edit(_ point: Point, to text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.emptyRefusal }
        guard let send = api.edit else { return nil }
        do {
            let saved = try await send(point.id, String(trimmed.prefix(AssistantMemoryAPI.maxLength)))
            replace(point.id) { _ in saved }
            return nil
        } catch {
            if case APIClient.APIError.http(404, _, _, _, _) = error { replace(point.id) { _ in nil } }
            return UserMessage.text(for: error)
        }
    }

    static var emptyRefusal: String {
        UserMessage.bulgarian["MEMORY_POINT_EMPTY"] ?? "Записът не може да бъде празен."
    }
}

extension ForgettableList where Item == AssistantMemoryAPI.Conversation {
    convenience init() {
        self.init(api: API(
            list: { try await AssistantMemoryAPI.conversations() },
            forget: { try await AssistantMemoryAPI.forgetConversation($0) },
            forgetAll: { try await AssistantMemoryAPI.forgetAllConversations() }))
    }
}
