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

    /// `days` is the REQUESTED window for the task trend.
    ///
    /// ── The sibling route is gone from this file, and its trap is not ──
    ///
    /// `/dashboard/trends` was modelled and deleted unused (see
    /// `TrendModels`). If the ten-series metric chart is ever built, note that
    /// the two routes DEFAULT TO DIFFERENT WINDOWS — 90 days there against 14
    /// here — so a screen that omits `days` on both compares a quarter with a
    /// fortnight. That is why this one is named at the call site rather than
    /// omitted.
    ///
    /// And a non-numeric value "falls back to the default rather than erroring,
    /// so a malformed client cannot break the chart — it silently gets the
    /// default window". Silently is the operative word: nonsense would draw a
    /// convincing chart of the wrong period. `exclusiveMinimum: 0`, so zero and
    /// negatives are clamped here rather than sent — a request this client
    /// KNOWS is invalid should not be made.
    static func taskTrendPath(days: Int? = nil) -> String {
        guard let days else { return "\(base)/dashboard/task-trend" }
        return "\(base)/dashboard/task-trend?days=\(max(days, 1))"
    }

    /// The server's own default for the one trend route this app draws.
    ///
    /// `metrics = 90` was here for `/dashboard/trends` and went with it.
    enum DefaultWindow {
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


    static func decodeTaskTrend(from data: Data) async throws -> FarmTaskTrend {
        try await APIClient.shared.decode(data, as: FarmTaskTrend.self)
    }

    static func decodeFieldBriefing(from data: Data) async throws -> FieldBriefingPayload {
        try await APIClient.shared.decode(data, as: FieldBriefingPayload.self)
    }
}
