import Foundation

/// The farm's agro warnings by day (agri-saas #3077): frost, unsuitable for
/// spraying, disease risk. What «Лунен календар» needs to strike its sowing
/// advice on a warned day (owner, 2026-11-15).
///
/// ── What an absence means ──
///
/// Only up to `horizon`, the last day a forecast actually informed. Past it
/// nothing is knowable, so the screen claims nothing there; `nil` is a farm
/// with no weather at all. `truncated` means the list was cut, so a missing
/// warning may simply not have arrived. An unknown `kind` is counted as a
/// warning of unknown type, never dropped: dropping is the direction that
/// hides a frost.
enum AgroSignalsAPI {
    static func path(from: Date, to: Date, calendar: Calendar = FarmRecordAPI.farmCalendar) -> String {
        "\(FarmPath.root)/agro/signals?from=\(BgDate.isoDay(from, in: calendar))&to=\(BgDate.isoDay(to, in: calendar))"
    }

    struct Page: Decodable, Sendable {
        struct Signal: Decodable, Sendable {
            let locationId: String
            let kind: String
            let signalDate: String
        }
        let signals: [Signal]
        let horizon: String?
        let frostThresholdC: Double?
        let truncated: Bool?
    }

    static func load(from: Date, to: Date) async throws -> LunarWarnings {
        let data = try await APIClient.shared.data(for: path(from: from, to: to))
        return warnings(try await APIClient.shared.decode(data, as: Page.self))
    }

    /// Blocks per day per kind, each block once a day.
    static func warnings(_ page: Page) -> LunarWarnings {
        var frost: [String: Set<String>] = [:], spray: [String: Set<String>] = [:], other: [String: Set<String>] = [:]
        for signal in page.signals {
            switch signal.kind {
            case "FROST_RISK": frost[signal.signalDate, default: []].insert(signal.locationId)
            // Claimed only when the day is unsuitable: its presence IS the warning.
            case "SPRAY_WINDOW": spray[signal.signalDate, default: []].insert(signal.locationId)
            // Known, and not about sowing.
            case "DISEASE_RISK": break
            default: other[signal.signalDate, default: []].insert(signal.locationId)
            }
        }
        return LunarWarnings(frostBlocks: frost.mapValues(\.count), sprayBlocks: spray.mapValues(\.count),
                             otherBlocks: other.mapValues(\.count), horizon: page.horizon,
                             frostThresholdC: page.frostThresholdC, truncated: page.truncated ?? false,
                             known: true)
    }
}
