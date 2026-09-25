import Foundation
import SwiftUI

/// What «Табло» can show, and what this farmer has chosen to see.
///
/// ── Customisable, on the owner's instruction, and LOCALLY ──
///
/// The bottom bar's order is synced through `PUT /api/account/bottom-tabs`
/// because the web shares it. There is no equivalent route for dashboard
/// blocks, so this is `@AppStorage` — per device, not per account, which is
/// the honest description of what it is. Inventing a server key for it would
/// be inventing a contract.
///
/// ── Why an explicit stored list and not "all minus the hidden ones" ──
///
/// A hidden-set means a block added in a later build appears unasked on a
/// screen somebody had already arranged. An explicit list means a new block is
/// OFF until chosen — which is the right default for a screen whose whole
/// point is that the farmer decided what belongs on it.
///
/// The cost is that a new block is invisible until someone opens the picker,
/// so the picker says how many are available rather than only listing what is
/// on.
enum DashboardBlock: String, CaseIterable, Identifiable, Sendable {
    case briefing
    case grainPrice
    case journal
    case taskTrend
    case tasks
    case lowStock
    case achievements

    var id: String { rawValue }

    var label: String {
        switch self {
        case .briefing: "Сателитно обобщение"
        case .grainPrice: "Цена на избрана култура"
        case .journal: "Последни записи"
        case .taskTrend: "Създадени и завършени задачи"
        case .tasks: "Моите задачи"
        case .lowStock: "Ниски наличности"
        case .achievements: "Постижения"
        }
    }

    var icon: String {
        switch self {
        case .briefing: "sparkles"
        case .grainPrice: "chart.line.uptrend.xyaxis"
        case .journal: "book.closed"
        case .taskTrend: "chart.bar"
        case .tasks: "checklist"
        case .lowStock: "shippingbox"
        case .achievements: "rosette"
        }
    }

    /// THE OWNER'S FOUR, chosen 2026-09-25.
    ///
    /// Briefing, the journal's latest, a chosen crop's price, and the
    /// created-against-completed chart. `tasks`, `lowStock` and `achievements`
    /// exist and are off: he was offered all seven and picked these. They stay
    /// in the enum so the picker can offer them rather than requiring a build.
    static let defaultOrder: [DashboardBlock] = [.briefing, .grainPrice, .journal, .taskTrend]
}

/// Which blocks are on, and which crop the price block follows.
///
/// A tiny `@Observable` rather than raw `@AppStorage` in the view, so the
/// picker and the screen read one source and the ORDER is storable — an
/// `@AppStorage` array of raw values keeps the farmer's arrangement, which a
/// `Set` would throw away.
/// ── This file HOLDS a commodity and never renders its name ──
///
/// The CI guard requires any file touching `.commodity` to name
/// `CommodityName`, because the failure it exists to catch is a new screen
/// writing `Text(row.commodity)` and shipping the server's English to a
/// Bulgarian farmer. This file stores a CHOICE of commodity, and every place
/// that choice becomes words goes through `ChartableCommodity.label`, which
/// resolves through `CommodityName.canonical`. Nothing here builds a name.
///
/// It tripped the guard on `Self.commodityKey` — a storage key whose spelling
/// happened to contain `.commodity` as a substring. Renamed to
/// `priceCommodityKey`, because a guard that fires on a preference key teaches
/// the next person to work around it, and a guard worked around is worth less
/// than one that is strict and correct.
@Observable
@MainActor
final class DashboardPreferences {
    static let shared = DashboardPreferences()

    private static let blocksKey = "dashboard.blocks"
    private static let priceCommodityKey = "dashboard.priceCommodity"

    private(set) var blocks: [DashboardBlock]
    private(set) var priceCommodity: ChartableCommodity

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.blocksKey)
        // An unrecognised raw value is DROPPED, not fatal: a block removed in a
        // later build must not strand a saved arrangement, the same rule
        // `AppSurface` applies to a bar order saved on the web.
        let restored = stored?.compactMap(DashboardBlock.init(rawValue:))
        blocks = restored ?? DashboardBlock.defaultOrder

        let commodity = UserDefaults.standard.string(forKey: Self.priceCommodityKey)
        priceCommodity = commodity.flatMap(ChartableCommodity.init(rawValue:)) ?? .wheat
    }

    func isOn(_ block: DashboardBlock) -> Bool { blocks.contains(block) }

    /// Toggling APPENDS rather than re-sorting, so turning a block on puts it
    /// at the end where the farmer expects a new thing, instead of teleporting
    /// it into the middle by enum order.
    func toggle(_ block: DashboardBlock) {
        if let index = blocks.firstIndex(of: block) {
            blocks.remove(at: index)
        } else {
            blocks.append(block)
        }
        UserDefaults.standard.set(blocks.map(\.rawValue), forKey: Self.blocksKey)
    }

    func move(from source: IndexSet, to destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination)
        UserDefaults.standard.set(blocks.map(\.rawValue), forKey: Self.blocksKey)
    }

    func select(_ commodity: ChartableCommodity) {
        priceCommodity = commodity
        UserDefaults.standard.set(commodity.rawValue, forKey: Self.priceCommodityKey)
    }

    /// For tests, which must not inherit whatever this device has stored.
    static func ephemeral(blocks: [DashboardBlock],
                          commodity: ChartableCommodity = .wheat) -> DashboardPreferences {
        let prefs = DashboardPreferences(blocks: blocks, commodity: commodity)
        return prefs
    }

    private init(blocks: [DashboardBlock], commodity: ChartableCommodity) {
        self.blocks = blocks
        self.priceCommodity = commodity
    }
}
