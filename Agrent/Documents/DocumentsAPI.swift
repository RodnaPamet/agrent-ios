import Foundation

/// «Документи» (#468): agri-saas #2495's routes, built against the shape
/// agreed with backend 1 (2026-10-30) and checked against its spec before
/// anything merges.
///
/// ── Never cached on disk ──
///
/// A document's name can name a third party («Договор аренда …»), which is
/// why the server encrypts it. So the list and the settings are read live,
/// as messaging and admin data are, and never go through `ResponseCache`.
enum DocumentsAPI {
    private static var base: String { "\(FarmPath.root)/documents" }

    /// The list, newest first. No query: there is nothing to filter by.
    static var listPath: String { base }
    static var settingsPath: String { "\(base)/settings" }
    static func documentPath(_ id: String) -> String { "\(base)/\(URLEscape.segment(id))" }
    /// The bytes, for the preview. 404 once purged.
    static func contentPath(_ id: String) -> String { "\(documentPath(id))/content" }
    /// An admin's «Опитай пак» on a FAILED Drive copy.
    static func driveCopyPath(_ id: String) -> String { "\(documentPath(id))/drive-copy" }

    static func list() async throws -> DocumentsPage {
        try await decodeList(from: APIClient.shared.data(for: listPath))
    }

    /// `{rows, truncated}`. A row that doesn't decode (no `id`) is dropped;
    /// the rest stay.
    static func decodeList(from data: Data) async throws -> DocumentsPage {
        let page = try await APIClient.shared.decode(data, as: Envelope.self)
        return DocumentsPage(items: page.rows.compactMap(\.value), truncated: page.truncated ?? false)
    }

    private struct Envelope: Decodable, Sendable {
        let rows: [Lossy]
        let truncated: Bool?
    }

    private struct Lossy: Decodable, Sendable {
        let value: FarmDocument?
        init(from decoder: any Decoder) throws { value = try? FarmDocument(from: decoder) }
    }

    static func settings() async throws -> DocumentSettings {
        try await APIClient.shared.decode(APIClient.shared.data(for: settingsPath), as: DocumentSettings.self)
    }

    /// An admin's change: the period for NEW uploads, and Drive on or off.
    struct SettingsChange: Encodable, Equatable, Sendable {
        let retention: String
        let driveSync: Bool
    }

    static func update(retention: DocumentRetention, driveSync: Bool) async throws -> DocumentSettings {
        try await APIClient.shared.put(
            settingsPath, body: SettingsChange(retention: retention.rawValue, driveSync: driveSync),
            as: DocumentSettings.self)
    }

    /// One document up, through the server's upload pipeline (scan, size,
    /// the farm's 2 GB). The name travels as its own field: a Cyrillic
    /// filename in a multipart header is a parser's guess, a text field is
    /// not. One key per upload, kept across a retry of the same bytes, so a
    /// lost answer can't make two documents.
    static func upload(_ file: Data, name: String, fileName: String, mimeType: String,
                       idempotencyKey: String) async throws -> FarmDocument {
        let data = try await APIClient.shared.postMultipart(
            listPath, file: file, fileName: fileName, mimeType: mimeType,
            fields: ["name": name], idempotencyKey: idempotencyKey)
        return try await APIClient.shared.decode(data, as: FarmDocument.self)
    }

    static func content(_ id: String) async throws -> (data: Data, fileName: String?) {
        try await APIClient.shared.getForDocument(contentPath(id))
    }

    static func delete(_ id: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(documentPath(id))
    }

    static func retryDriveCopy(_ id: String) async throws {
        _ = try await APIClient.shared.postReturningData(
            driveCopyPath(id), body: EmptyBody(), idempotencyKey: nil)
    }

    private struct EmptyBody: Encodable, Sendable {}

}
