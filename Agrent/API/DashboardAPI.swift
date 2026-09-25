import Foundation

/// The four dashboard reads.
///
/// FOUR SEPARATE CALLS, not one. The server has no combined route, the two
/// trend endpoints answer with different envelopes, and the briefing is under
/// `/reports` rather than `/dashboard`. A client that fetched them as one unit
/// would fail all four when any one failed, on a screen whose sections are
/// independent — so each is its own resource with its own cache entry and its
/// own failure.
enum DashboardAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)" }

    static var agPath: String { "\(base)/dashboard/ag" }

    /// `days` is the REQUESTED window. The answer may cover fewer — see
    /// `TrendPayload.isPartial`.
    ///
    /// ── The two defaults differ, and a bad value is silent ──
    ///
    /// Omitting `days` is not one behaviour: `/dashboard/trends` defaults to
    /// **90** and `/dashboard/task-trend` to **14**. Two sibling routes, two
    /// windows — so a screen that omits the parameter on both is comparing a
    /// quarter against a fortnight, which is exactly the sort of thing that
    /// looks like a data story.
    ///
    /// And the spec says a non-numeric value "falls back to the default rather
    /// than erroring, so a malformed client cannot break the chart — it
    /// silently gets the default window". Silently is the operative word: a
    /// client that sent nonsense would draw a perfectly convincing chart of the
    /// wrong period. `exclusiveMinimum: 0`, so zero and negatives are out of
    /// range; clamped here rather than sent, because a request this client
    /// KNOWS is invalid should not be made.
    static func trendsPath(days: Int? = nil) -> String {
        guard let days else { return "\(base)/dashboard/trends" }
        return "\(base)/dashboard/trends?days=\(max(days, 1))"
    }

    static func taskTrendPath(days: Int? = nil) -> String {
        guard let days else { return "\(base)/dashboard/task-trend" }
        return "\(base)/dashboard/task-trend?days=\(max(days, 1))"
    }

    /// The server's own defaults, named so a caller can pass the SAME window to
    /// both rather than inheriting two different ones by omission.
    enum DefaultWindow {
        static let metrics = 90
        static let tasks = 14
    }

    /// Under `/reports`, not `/dashboard`. The prefix is not cosmetic: the
    /// server's operator lockdown works on prefixes, so this is a different
    /// surface from the three above and may be visible to a different set of
    /// roles.
    static var fieldBriefingPath: String { "\(base)/reports/field-briefing" }

    static func decodeAg(from data: Data) async throws -> AgDashboard {
        try await APIClient.shared.decode(data, as: AgDashboard.self)
    }

    static func decodeTrends(from data: Data) async throws -> TrendPayload {
        try await APIClient.shared.decode(data, as: TrendPayload.self)
    }

    static func decodeTaskTrend(from data: Data) async throws -> FarmTaskTrend {
        try await APIClient.shared.decode(data, as: FarmTaskTrend.self)
    }

    static func decodeFieldBriefing(from data: Data) async throws -> FieldBriefingPayload {
        try await APIClient.shared.decode(data, as: FieldBriefingPayload.self)
    }
}
