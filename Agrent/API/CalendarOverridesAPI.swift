import Foundation

/// The agro calendar's corrections (agri-saas#3095 stage 2, #3176): the
/// platform farm's owner or admins correct a cited window or add one МЗХ does
/// not publish, with a written basis. Global — every farm sees the result —
/// which is why only the platform farm is offered it, and why the server
/// checks the platform tenant again on every request.
enum CalendarOverridesAPI {
    private static var base: String { "\(FarmPath.root)/admin/agro-calendar/overrides" }
    static var listPath: String { base }
    static func windowPath(_ windowID: String) -> String { "\(base)/\(URLEscape.segment(windowID))" }

    /// A window as an override carries it: the calendar's fields, no citation.
    struct WindowDraft: Codable, Equatable, Hashable, Sendable {
        var id: String
        var kind: String
        var band: String?
        var region: String
        var from: String
        var to: String
        var title: Words?
    }

    struct Words: Codable, Equatable, Hashable, Sendable {
        var bg: String
    }

    struct Override: Decodable, Identifiable, Equatable, Sendable {
        let windowId: String
        let cropKey: String
        /// `corrected` or `added`.
        let origin: String
        let window: WindowDraft
        let basis: Words
        let authorRef: String
        let setAt: String
        var id: String { windowId }
        var isAddition: Bool { origin == "added" }
    }

    private struct List: Decodable { let overrides: [Override] }
    private struct Body: Encodable {
        let cropKey: String
        let window: WindowDraft
        let basis: Words
    }

    static func list() async throws -> [Override] {
        let data = try await APIClient.shared.data(for: listPath)
        return try await APIClient.shared.decode(data, as: List.self).overrides
    }

    /// Correct (the window's id is cited for that crop) or add (a new id).
    /// The server decides which from the id.
    static func set(cropKey: String, window: WindowDraft, basis: String) async throws {
        _ = try await APIClient.shared.putReturningData(
            listPath, body: Body(cropKey: cropKey, window: window, basis: Words(bg: basis)))
    }

    /// A correction gives МЗХ's window back; an addition disappears.
    static func clear(_ windowID: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(windowPath(windowID))
    }
}

extension CalendarOverridesAPI.WindowDraft {
    /// A calendar window as the editor starts from it: the same fields, no citation.
    init(_ w: AgroCalendar.Window) {
        self.init(id: w.id, kind: w.kind.rawValue, band: w.band, region: w.region,
                  from: w.from, to: w.to, title: w.title?.bg.map(CalendarOverridesAPI.Words.init(bg:)))
    }
}
