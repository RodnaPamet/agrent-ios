import Foundation

/// «В страната» on Табло (agrent-ios#635, owner 2026-11-17): the field
/// campaign's progress from МЗХ's weekly bulletin, served by agri-saas#3174.
/// Harvest as a SHARE, sowing as hectares and the change on last year — МЗХ
/// gives no plan to divide sowing by.
struct CampaignProgress: Decodable, Equatable, Sendable {
    /// The newest «към» date among the tables, `YYYY-MM-DD`.
    let asOf: String
    let harvest: [Table<HarvestRow>]
    let sowing: [Table<SowingRow>]

    struct Table<Row: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
        let asOf: String
        let lastYear: Int
        let rows: [Row]
    }

    /// The crop is named as МЗХ printed it («царевица за зърно»): the label is
    /// the bulletin's own word, and the line quotes the bulletin.
    struct HarvestRow: Decodable, Equatable, Sendable {
        let label: String
        let harvestedPct: Int
    }

    struct SowingRow: Decodable, Equatable, Sendable {
        let label: String
        let sownHa: Int
        let lastYearHa: Int?
        /// As printed, with a point: "16.6", "-28.4"; nil where МЗХ printed «-».
        let changePct: String?
    }

    var isEmpty: Bool { harvest.allSatisfy(\.rows.isEmpty) && sowing.allSatisfy(\.rows.isEmpty) }
}

/// `{ progress: … | null }` — null until the server has read a bulletin with
/// progress tables, which is a normal state, not a failure.
struct CampaignProgressResponse: Decodable, Equatable, Sendable {
    let progress: CampaignProgress?
}

enum CampaignProgressAPI {
    static let path = "/api/agro-progress"

    static func decode(_ data: Data) async throws -> CampaignProgressResponse {
        try await APIClient.shared.decode(data, as: CampaignProgressResponse.self)
    }
}

/// The words, as the owner approved them (2026-11-17):
///
///     В СТРАНАТА · към 5 ноември
///     Ожънати: слънчоглед 99%, царевица 92%
///     Засети: пшеница 767 199 ха (+16,6% спрямо 2025)
///     Източник: МЗХ
enum CampaignWords {
    static let title = "В страната"
    static let source = "Източник: МЗХ"

    /// «към 5 ноември», from the server's day.
    static func asOf(_ day: String) -> String? {
        BgDate.parseISODay(day).map { "към \(BgDate.dayMonth($0))" }
    }

    /// «Ожънати: слънчоглед 99%, царевица 92%», or nil with nothing harvested.
    static func harvest(_ progress: CampaignProgress) -> String? {
        let parts = progress.harvest.flatMap(\.rows).map { "\($0.label) \($0.harvestedPct)%" }
        return parts.isEmpty ? nil : "Ожънати: " + parts.joined(separator: ", ")
    }

    /// One line per crop sown: «Засети: пшеница 767 199 ха (+16,6% спрямо 2025)».
    static func sowing(_ progress: CampaignProgress) -> [String] {
        progress.sowing.flatMap { table in
            table.rows.map { row in
                var line = "Засети: \(row.label) \(hectares(row.sownHa)) ха"
                if let change = row.changePct.flatMap(changeText) {
                    line += " (\(change) спрямо \(table.lastYear))"
                }
                return line
            }
        }
    }

    /// «767 199» — grouped as Bulgarian groups thousands.
    static func hectares(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(BgDate.locale))
    }

    /// "16.6" → «+16,6%»; "-28.4" → «−28,4%»; "0.0" → «0,0%». Nil for text
    /// that is not a number, so a malformed figure is left out, not shown.
    static func changeText(_ printed: String) -> String? {
        guard let value = Double(printed) else { return nil }
        let digits = printed.trimmingCharacters(in: CharacterSet(charactersIn: "+-")).replacingOccurrences(of: ".", with: ",")
        if value > 0 { return "+\(digits)%" }
        if value < 0 { return "−\(digits)%" }
        return "\(digits)%"
    }
}
