import Foundation

/// `GET /grain/costs/summary` (agri-saas #2656, #503): exact totals over
/// EVERY cost of the farm, per type and per type and month, each per
/// currency. What «Разходи»'s rows, «Общо» and both graphs add up, in place
/// of the phone's own summing over the list, which holds the newest 500
/// only and so was wrong without saying so on a farm with more.
///
/// Only two of the four arrays are read. `byMonth` is `byTypeAndMonth`
/// re-summed, and `currencies` is `byType`'s, as the server states, so
/// reading them again would be two sources for one number.
///
/// ── Money ──
///
/// `totalMinor` is integer cents, summed in Postgres numerics. The phone
/// adds integers and divides by 100 in `Decimal` for display only, so
/// nothing is rounded twice (backend 1, 2026-11-02).
///
/// Strict: a row that does not read fails the summary, and the screen
/// falls back to the plain list. A dropped row would be a wrong total that
/// nobody could see.
struct CostSummary: Decodable, Equatable, Sendable {
    struct TypeTotal: Decodable, Equatable, Sendable {
        let category: CostCategory
        let currency: String
        let totalMinor: Int
        let count: Int
    }

    struct TypeMonthTotal: Decodable, Equatable, Sendable {
        let category: CostCategory
        /// `YYYY-MM`: a month, not an instant, so no time zone moves it.
        let month: String
        let currency: String
        let totalMinor: Int
        let count: Int
    }

    let byType: [TypeTotal]
    let byTypeAndMonth: [TypeMonthTotal]
}

extension CostsAPI {
    /// No query: every type and every day, so a chip changes the screen
    /// without a round trip (`byTypeAndMonth` re-sums exactly).
    static var summaryPath: String { "\(listPath)/summary" }

    static func decodeSummary(from data: Data) async throws -> CostSummary {
        try await APIClient.shared.decode(data, as: CostSummary.self)
    }
}
