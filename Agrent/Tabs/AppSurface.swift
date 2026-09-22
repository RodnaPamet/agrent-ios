import SwiftUI

/// Every screen that can sit in the bottom row, keyed by the web's own
/// route suffix.
///
/// ── Why the raw values are paths ──
///
/// The stored order is ONE array shared with the web, and `BottomTabBar`
/// there matches on `href.endsWith(suffix)`. If iOS invented `"journal"`
/// while the web used `"/journal"`, the sync would be per-client while
/// looking like it worked. Suffixes are opaque strings and two of the
/// web's are two segments deep, so nothing here may assume one path
/// component.
///
/// ── Unknown ids are ignored, not errors ──
///
/// The web offers twenty-two surfaces and this app has seven of them. An
/// order saved from a laptop will contain `/dashboard`, which iOS cannot
/// draw — that is normal and must degrade to "not shown", never to a
/// failed load or a refused save.
enum AppSurface: String, CaseIterable, Identifiable, Sendable {
    case journal = "/journal"
    case calculator = "/grain/calculator"
    case exchange = "/exchange"
    case locations = "/locations"
    case tasks = "/farm-tasks"
    case trends = "/trends"
    case news = "/news"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .journal: "Дневник"
        case .calculator: "Калкулатор"
        case .exchange: "Борса"
        case .locations: "Локации"
        case .tasks: "Задачи"
        case .trends: "Тенденции"
        case .news: "Новини"
        }
    }

    var icon: String {
        switch self {
        case .journal: "book.closed"
        case .calculator: "plusminus"
        case .exchange: "arrow.left.arrow.right"
        case .locations: "map"
        case .tasks: "checklist"
        case .trends: "chart.line.uptrend.xyaxis"
        case .news: "newspaper"
        }
    }

    /// Today's bottom row, in today's order.
    ///
    /// NOT the web's default, which is `/dashboard /farm-tasks /locations
    /// /journal /exchange` — this app has no dashboard, and reordering the
    /// four it shares on the day a customiser ships would move things
    /// under a farmer who never asked for that. The default is what is
    /// already on their phone; the customiser is how it changes.
    static let fallback: [AppSurface] = [.journal, .calculator, .exchange, .locations, .tasks]

    /// iOS collapses a sixth tab and everything after it into "More",
    /// which buries features behind an extra tap and reads as a bug.
    static let capacity = 5

    @ViewBuilder
    var screen: some View {
        switch self {
        case .journal: JournalListView()
        case .calculator: CalculatorView()
        case .exchange: ExchangeView()
        case .locations: LocationsView()
        case .tasks: TasksListView()
        case .trends: TrendsView()
        case .news: NewsView()
        }
    }
}
