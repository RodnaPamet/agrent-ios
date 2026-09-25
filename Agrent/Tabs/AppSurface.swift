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
/// The web offers twenty-two surfaces and this app has nine of them. An
/// order saved from a laptop will contain suffixes iOS cannot draw — that is
/// normal and must degrade to "not shown", never to a failed load or a refused
/// save.
///
/// `/dashboard` USED TO BE ONE OF THOSE and no longer is. It is the first
/// entry in the web's default order, so every order ever saved from a laptop
/// already carries it, and adding the case means those orders resolve rather
/// than silently dropping an entry. A farmer who arranged their bar on the web
/// gets what they arranged; nobody's existing iOS order changes, because
/// `fallback` is untouched.
enum AppSurface: String, CaseIterable, Identifiable, Sendable {
    case journal = "/journal"
    case calculator = "/grain/calculator"
    case exchange = "/exchange"
    case locations = "/locations"
    case tasks = "/farm-tasks"
    case trends = "/trends"
    case news = "/news"
    case farmRisk = "/farm-risk"
    case dashboard = "/dashboard"

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
        case .farmRisk: "Риск"
        case .dashboard: "Табло"
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
        case .farmRisk: "exclamationmark.shield"
        case .dashboard: "square.grid.2x2"
        }
    }

    /// Reachable by a MECHANISATOR.
    ///
    /// Derived from the server's own allowlist — a screen qualifies only
    /// if every tenant-scoped call it makes is inside
    /// `farm-tasks|field-operations|tasks|locations|agro`:
    ///
    ///   Локации   → locations, agro, field-operations   ✓
    ///   Задачи    → farm-tasks, tasks                   ✓
    ///   Дневник   → journal                             403
    ///   Калкулатор → grain                              403
    ///   Борса     → exchange                            403
    ///   Тенденции → trends                              403
    ///   Новини    → trends/news                         403
    ///
    /// Which is the same division the rest of the app already records:
    /// an operator's job is COMPLETION, not creation.
    var isOperatorAllowed: Bool {
        switch self {
        // The READINGS are reachable: `/agro` and `/locations` are both in
        // the operator allowlist. Only `/insurance` is not, so a
        // MECHANISATOR sees every parcel's vegetation and moisture and is
        // not offered the ask — which is the right division. Knowing a
        // field is stressed is field work; contacting an insurer is not.
        case .locations, .tasks, .farmRisk: true
        // NOT VERIFIED EITHER WAY, and false is the conservative reading of
        // an unverified prefix rather than a finding. Whether `/dashboard` is
        // in the server's operator allowlist is not something this app has
        // been told, and six of the nine surfaces are already false — so this
        // matches the majority rather than inventing a permission.
        //
        // The cost of being wrong here is a screen an operator could have used
        // and does not see, which is reversible in one line. The cost the other
        // way is four requests that 403 on a screen built to show four blocks.
        // Asked of the server session.
        case .dashboard: false
        case .journal, .calculator, .exchange, .trends, .news: false
        }
    }

    /// Today's bottom row, in today's order.
    ///
    /// NOT the web's default, which is `/dashboard /farm-tasks /locations
    /// /journal /exchange`. This app now HAS a dashboard, and it still does not
    /// go in the default row: reordering somebody's bar on the day a screen
    /// ships would move things under a farmer who never asked for that. The
    /// default is what is already on their phone; the customiser is how it
    /// changes, and «Табло» is one of the nine it offers.
    static let fallback: [AppSurface] = [.journal, .calculator, .exchange, .locations, .tasks]

    static func fallback(isOperator: Bool) -> [AppSurface] {
        isOperator ? fallback.filter(\.isOperatorAllowed) : fallback
    }

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
        case .farmRisk: FarmRiskView()
        case .dashboard: DashboardView()
        }
    }
}
