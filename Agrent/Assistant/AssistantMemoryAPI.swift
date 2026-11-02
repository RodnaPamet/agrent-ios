import Foundation

/// What the assistant remembers about the person (#507, agri-saas #2686):
/// `/api/account/assistant-memory`, per PERSON across farms, so under
/// `/api/account` and never a farm's path (owner, 2026-11-01: "per person,
/// across farms").
///
/// The person sees it, corrects it and deletes it ("Yes, see and delete").
/// A deleted point stays deleted: the server never learns it again from the
/// same words (rule 5 of the design the owner adopted). An edited one is the
/// person's and is never rewritten (rule 6).
enum AssistantMemoryAPI {
    static let path = "/api/account/assistant-memory"
    static func pointPath(_ id: String) -> String { "\(path)/\(URLEscape.segment(id))" }

    /// Both halves answer 404 while it is off (agri-saas #2711: "one screen,
    /// one switch"), so Профил offers the screen only where it is on.
    static let flag = "assistant.memory"

    /// One remembered point, in the person's own language.
    struct Point: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let text: String
        let rememberedAt: Date?

        private enum CodingKeys: String, CodingKey { case id, text, rememberedAt }

        init(id: String, text: String, rememberedAt: Date?) {
            self.id = id
            self.text = text
            self.rememberedAt = rememberedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            rememberedAt = try? c.decodeIfPresent(Date.self, forKey: .rememberedAt)
        }
    }

    /// The server's limit on one point's text.
    static let maxLength = 280

    static func list() async throws -> [Point] {
        try await decodeList(from: APIClient.shared.data(for: path))
    }

    /// A point that does not read costs that point, never the list.
    static func decodeList(from data: Data) async throws -> [Point] {
        struct Envelope: Decodable {
            let facts: [Lossy]
        }
        struct Lossy: Decodable {
            let value: Point?
            init(from decoder: Decoder) throws { value = try? Point(from: decoder) }
        }
        return try await APIClient.shared.decode(data, as: Envelope.self).facts.compactMap(\.value)
    }

    /// Forget one. A point already gone (404 `MEMORY_POINT_NOT_FOUND`) is
    /// what was asked for.
    static func forget(_ id: String) async throws {
        do {
            _ = try await APIClient.shared.deleteReturningData(pointPath(id))
        } catch APIClient.APIError.http(404, _, _, _, _) {
            return
        }
    }

    /// «Изтрий всичко».
    static func forgetAll() async throws {
        _ = try await APIClient.shared.deleteReturningData(path)
    }

    private struct Edit: Encodable, Sendable { let text: String }

    /// The person's own wording, which the server then never rewrites.
    static func edit(_ id: String, text: String) async throws -> Point {
        let data = try await APIClient.shared.patchReturningData(pointPath(id), body: Edit(text: text))
        return try await APIClient.shared.decode(data, as: Point.self)
    }

    // MARK: - Past conversations (#521, agri-saas #2711)

    /// Every exchange the person had with the assistant, from every farm,
    /// newest first; kept while the account exists.
    static let conversationsPath = "/api/account/assistant-conversations"
    static func conversationPath(_ id: String) -> String { "\(conversationsPath)/\(URLEscape.segment(id))" }

    /// One past exchange, recognisable by the person's own first question
    /// (`opening`), never a generated summary. Nil for an exchange abandoned
    /// before a question landed.
    struct Conversation: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let opening: String?
        let lastTurnAt: Date?
        /// The turns it holds, the assistant's answers included.
        let turns: Int

        private enum CodingKeys: String, CodingKey { case id, opening, lastTurnAt, turns }

        /// An encryption envelope (`v2:` and base64), never words. Turn text
        /// is sealed under the FARM's key, and a read across a person's
        /// farms resolved no key, so until agri-saas #2722 the list sent
        /// every `opening` sealed, which would have been every row's label
        /// (backend 2, 2026-11-02). Read as no question, never shown: a
        /// person must not read ciphertext as their own words, whatever a
        /// server does next.
        static func isSealed(_ text: String) -> Bool {
            text.range(of: #"^v[0-9]+:[A-Za-z0-9+/=_-]{16,}$"#, options: .regularExpression) != nil
        }

        init(id: String, opening: String?, lastTurnAt: Date?, turns: Int) {
            self.id = id
            self.opening = opening
            self.lastTurnAt = lastTurnAt
            self.turns = turns
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            let said = (try? c.decodeIfPresent(String.self, forKey: .opening))?.recorded
            opening = said.flatMap { Self.isSealed($0) ? nil : $0 }
            lastTurnAt = try? c.decodeIfPresent(Date.self, forKey: .lastTurnAt)
            turns = (try? c.decodeIfPresent(Int.self, forKey: .turns)) ?? 0
        }
    }

    static func conversations() async throws -> [Conversation] {
        try await decodeConversations(from: APIClient.shared.data(for: conversationsPath))
    }

    /// A row that does not read costs that row, never the list.
    static func decodeConversations(from data: Data) async throws -> [Conversation] {
        struct Envelope: Decodable {
            let conversations: [Lossy]
        }
        struct Lossy: Decodable {
            let value: Conversation?
            init(from decoder: Decoder) throws { value = try? Conversation(from: decoder) }
        }
        return try await APIClient.shared.decode(data, as: Envelope.self).conversations.compactMap(\.value)
    }

    /// One past exchange to read and continue (#525, agri-saas #2722): its
    /// turns oldest first, as a transcript reads.
    struct PastConversation: Decodable, Equatable, Sendable {
        let id: String
        let items: [Item]
        /// The exchange is longer than `items`: the OLDEST turns were left
        /// out, so the end always agrees with the list's day.
        let truncated: Bool

        struct Item: Decodable, Equatable, Sendable {
            let role: Role
            /// Nil when the server holds the turn and could not read it:
            /// "never a storage envelope" (agri-saas #2722). An envelope
            /// that arrives anyway reads as nil too (`Conversation.isSealed`).
            let text: String?

            enum Role: String, Decodable, Sendable { case user, assistant }

            private enum CodingKeys: String, CodingKey { case role, text }

            init(role: Role, text: String?) {
                self.role = role
                self.text = text
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                role = try c.decode(Role.self, forKey: .role)
                let said = (try? c.decodeIfPresent(String.self, forKey: .text))?.recorded
                text = said.flatMap { Conversation.isSealed($0) ? nil : $0 }
            }
        }

        private enum CodingKeys: String, CodingKey { case id, items, truncated }

        init(id: String, items: [Item], truncated: Bool) {
            self.id = id
            self.items = items
            self.truncated = truncated
        }

        /// A turn that does not read costs that turn, never the exchange.
        init(from decoder: Decoder) throws {
            struct Lossy: Decodable {
                let value: Item?
                init(from decoder: Decoder) throws { value = try? Item(from: decoder) }
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            items = try c.decode([Lossy].self, forKey: .items).compactMap(\.value)
            truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        }
    }

    static func pastConversation(_ id: String) async throws -> PastConversation {
        let data = try await APIClient.shared.data(for: conversationPath(id))
        return try await APIClient.shared.decode(data, as: PastConversation.self)
    }

    /// Forget one. Gone already, or never this person's, is
    /// `CONVERSATION_NOT_FOUND` (deliberately one answer): what was asked for.
    static func forgetConversation(_ id: String) async throws {
        do {
            _ = try await APIClient.shared.deleteReturningData(conversationPath(id))
        } catch APIClient.APIError.http(404, _, _, _, _) {
            return
        }
    }

    /// «Изтрий всички разговори». The remembered points stay.
    static func forgetAllConversations() async throws {
        _ = try await APIClient.shared.deleteReturningData(conversationsPath)
    }
}
