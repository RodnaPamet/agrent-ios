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

    /// `days` is the requested window. The answer may cover FEWER — see
    /// `TrendPayload.isPartial`.
    static func trendsPath(days: Int? = nil) -> String {
        guard let days else { return "\(base)/dashboard/trends" }
        return "\(base)/dashboard/trends?days=\(days)"
    }

    static func taskTrendPath(days: Int? = nil) -> String {
        guard let days else { return "\(base)/dashboard/task-trend" }
        return "\(base)/dashboard/task-trend?days=\(days)"
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
