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
}
