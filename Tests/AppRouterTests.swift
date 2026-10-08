import SwiftUI
import XCTest
@testable import Agrent

/// The router behind the tabs (agrent-ios#194, P4.5): what a re-tap, a
/// changed bar and `open(_:)` do to each tab's path. Pure — nothing is drawn.
@MainActor
final class AppRouterTests: XCTestCase {

    private let bar: [AppSurface] = [.journal, .calculator, .exchange, .locations, .tasks]

    private func thread(_ id: String) -> AppRoute {
        .conversation(threadID: id, commodity: "wheat")
    }

    private func path(_ routes: AppRoute...) -> NavigationPath {
        NavigationPath(routes)
    }

    /// The keys `WorkItemSummaryTests` measured on the list route; invented
    /// values.
    private func task(_ id: String) throws -> AppRoute {
        .task(try APIClientTestDecoder.decode(WorkItemSummary.self, from: #"""
        {"id":"\#(id)","key":"AGT-1","title":"Синтетична задача",
         "type":"FIELD_OPERATION","status":"OPEN","severity":"MEDIUM",
         "dueAt":null,"assignee":null,"assigneeUserId":null,
         "createdAt":"2026-09-18T07:12:00.000Z","updatedAt":"2026-09-20T09:30:00.000Z"}
        """#))
    }

    private func listing(_ id: String, price: String) -> ExchangeListing {
        ExchangeListing(
            id: id, side: .sell, kind: .culture, status: .active,
            commodity: "wheat", quantityTonnes: "100", pricePerTonne: price,
            priceCurrency: "EUR", regionCode: "BG-16", regionName: "Пловдив",
            lat: nil, lon: nil, description: nil, sellerDisplayName: nil,
            createdAt: Date(timeIntervalSince1970: 0), expiresAt: nil, isOwn: false
        )
    }

    // MARK: - Tabs

    func testItStartsOnTheFirstTabWithNothingPushed() {
        let router = AppRouter(bar: bar)
        XCTAssertEqual(router.tab, .journal)
        XCTAssertTrue(router.paths.isEmpty)
    }

    /// The one gesture the router exists to hear today: `TabView` writes the
    /// selection again when the selected tab is tapped.
    func testARetapPopsTheSelectedTabToItsRoot() {
        let router = AppRouter(bar: bar)
        router.tab = .exchange
        router.paths[.exchange] = path(thread("t1"), thread("t2"))
        router.tab = .exchange
        XCTAssertNil(router.paths[.exchange], "a re-tap left the tab's screens pushed")
        XCTAssertEqual(router.tab, .exchange)
    }

    /// Changing tab is not a re-tap: each tab keeps what it had pushed.
    func testSwitchingTabsKeepsEachTabsScreens() {
        let router = AppRouter(bar: bar)
        router.tab = .exchange
        router.paths[.exchange] = path(thread("t1"))
        router.tab = .tasks
        router.tab = .exchange
        XCTAssertEqual(router.paths[.exchange], path(thread("t1")))
    }

    /// A tab moved into the menu draws there as a sheet with its own stack;
    /// what it had pushed must not come back with it later.
    func testATabThatLeavesTheBarLeavesItsScreensBehind() {
        let router = AppRouter(bar: bar)
        router.tab = .exchange
        router.paths[.exchange] = path(thread("t1"))
        router.paths[.journal] = path(thread("t2"))

        router.adoptBar([.journal, .calculator, .locations, .tasks, .dashboard])
        XCTAssertNil(router.paths[.exchange])
        XCTAssertEqual(router.paths[.journal], path(thread("t2")), "a tab still on the bar lost its path")
        XCTAssertEqual(router.tab, .journal, "the selected tab left the bar and stayed selected")
    }

    func testTheSelectedTabSurvivesABarThatStillHasIt() {
        let router = AppRouter(bar: bar)
        router.tab = .locations
        router.adoptBar([.locations, .journal])
        XCTAssertEqual(router.tab, .locations)
    }

    /// What a stack's own back button does: the binding writes the shorter
    /// path, and a stack popped to its root leaves no entry behind.
    func testThePathBindingPopsBackToNoEntry() {
        let router = AppRouter(bar: bar)
        router[path: .exchange] = path(thread("t1"), thread("t2"))
        router[path: .exchange].removeLast()
        XCTAssertEqual(router.paths[.exchange], path(thread("t1")))
        router[path: .exchange].removeLast()
        XCTAssertNil(router.paths[.exchange])
        XCTAssertEqual(router[path: .journal], NavigationPath(), "a tab never pushed must read as its root")
    }

    /// The path takes a screen's own values beside the app's routes — why it
    /// is a `NavigationPath` (a parcel's history pushes its cards' lists).
    func testAPathHoldsAScreensOwnValuesBesideRoutes() {
        let router = AppRouter(bar: bar)
        router[path: .tasks] = path(thread("t1"))
        router[path: .tasks].append("a screen's own value")
        XCTAssertEqual(router[path: .tasks].count, 2)
    }

    // MARK: - open(_:)

    func testOpenShowsARouteOnItsOwnTab() throws {
        let router = AppRouter(bar: bar)
        router.paths[.tasks] = path(try task("old"))
        try router.open(task("wi_9"))
        XCTAssertEqual(router.tab, .tasks)
        XCTAssertEqual(router.paths[.tasks], path(try task("wi_9")),
                       "the route must be the only screen pushed on its tab")
    }

    /// Борса in the menu: its sheets keep their own stacks, so the route
    /// goes on top of the tab in front of the person.
    func testOpenWithItsTabOffTheBarPushesOntoTheCurrentTab() {
        let router = AppRouter(bar: [.journal, .calculator, .locations, .tasks])
        router.tab = .locations
        router.paths[.locations] = path(thread("t0"))
        router.open(thread("t1"))
        XCTAssertEqual(router.tab, .locations)
        XCTAssertEqual(router.paths[.locations], path(thread("t0"), thread("t1")))
        XCTAssertNil(router.paths[.exchange])
    }

    // MARK: - AppRoute

    func testEachRouteNamesTheTabItBelongsTo() throws {
        XCTAssertEqual(thread("t1").home, .exchange)
        XCTAssertEqual(AppRoute.listing(listing("l1", price: "200")).home, .exchange)
        XCTAssertEqual(try task("wi_1").home, .tasks)
        XCTAssertEqual(AppRoute.parcelHistory(parcelID: "p1", parcelName: "Синтетичен").home, .farmRisk)
    }

    /// Hashed by identity, compared in full: the same listing re-read with a
    /// new price is a different value that hashes alike — allowed, and
    /// cheaper than hashing a listing's payload.
    func testRoutesHashByIdentityAndCompareInFull() {
        let before = AppRoute.listing(listing("l1", price: "200"))
        let after = AppRoute.listing(listing("l1", price: "210"))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.hashValue, after.hashValue)
        XCTAssertEqual(Set([before, AppRoute.listing(listing("l1", price: "200"))]).count, 1)
        XCTAssertNotEqual(thread("t1").hashValue, thread("t2").hashValue)
    }
}

/// Every screen that can sit on the bar keeps its stack in the router. A
/// root left on a bare `NavigationStack` would still draw — and silently
/// miss the re-tap and `open(_:)`.
///
/// Source-reading: which view an `AppSurface` draws, and what that view's
/// body opens with, have no runtime hook a unit test can reach.
@MainActor
final class RoutedStackTests: XCTestCase {

    private static let roots: [AppSurface: String] = [
        .journal: "Agrent/Journal/JournalListView.swift",
        .calculator: "Agrent/Calculator/CalculatorView.swift",
        .exchange: "Agrent/Exchange/ExchangeView.swift",
        .locations: "Agrent/Locations/LocationsView.swift",
        .tasks: "Agrent/Tasks/TasksListView.swift",
        .trends: "Agrent/Trends/TrendsView.swift",
        .news: "Agrent/Trends/NewsView.swift",
        .farmRisk: "Agrent/FarmRisk/FarmRiskView.swift",
        .dashboard: "Agrent/Dashboard/DashboardView.swift",
    ]

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEverySurfaceRootIsARoutedStack() throws {
        XCTAssertEqual(Set(Self.roots.keys), Set(AppSurface.allCases),
                       "a new surface: list its root file here")
        let surfaces = SignOutHygieneTests.code(try source("Agrent/Tabs/AppSurface.swift"))
        for (surface, path) in Self.roots {
            // Positive control: this file's type is what the surface draws.
            let type = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            XCTAssertTrue(surfaces.contains("case .\(surface): \(type)()"),
                          "\(surface) no longer draws \(type) — fix the list above")
            let code = SignOutHygieneTests.code(try source(path))
            XCTAssertTrue(code.contains("RoutedStack {"),
                          "\(type) roots on a bare NavigationStack, outside the router")
        }
    }

    /// Registered once, at the root: a second registration for `AppRoute` in
    /// the same stack is ignored at runtime, with only a console warning.
    func testRoutesBecomeScreensInOnePlace() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50, "positive control: the app's sources were not found")
        let registering = try files.filter {
            SignOutHygieneTests.code(try String(contentsOf: $0, encoding: .utf8))
                .contains("navigationDestination(for: AppRoute.self)")
        }
        XCTAssertEqual(registering.map(\.lastPathComponent), ["RoutedStack.swift"])
    }

    /// SwiftUI does not mix its two ways of pushing in one stack — a view
    /// inside a link, and a value on the path — and every tab's stack takes
    /// values. So: no link that pushes a view and no
    /// `navigationDestination(item:)` / `(isPresented:)`, except in the files
    /// whose stacks the router never holds.
    func testNothingPushesAViewOntoARoutedStack() throws {
        // Stacks of their own, outside every tab: Админ's sheet, the no-farm
        // screen, and the form picker, which only sheets' forms use.
        let ownStacks: Set<String> = ["AdminView.swift", "FarmGate.swift", "FormChrome.swift"]
        let pushesAView = #"NavigationLink\s*\{|NavigationLink\([^)]*destination:|NavigationLink\("[^"]*"\)\s*\{"#

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default
            .enumerator(at: root.appendingPathComponent("Agrent"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files {
            let code = SignOutHygieneTests.code(try String(contentsOf: file, encoding: .utf8))
            let name = file.lastPathComponent
            if code.contains("navigationDestination(item:") || code.contains("navigationDestination(isPresented:") {
                offenders.append("\(name): navigationDestination(item:/isPresented:)")
            }
            if !ownStacks.contains(name), code.range(of: pushesAView, options: .regularExpression) != nil {
                offenders.append("\(name): a NavigationLink that pushes a view")
            }
        }
        XCTAssertEqual(offenders, [], "push a value instead — NavigationLink(value:) or pushRoute")

        // Positive control: the pattern does find the view-pushing links in
        // a file allowed to have them.
        let admin = SignOutHygieneTests.code(try source("Agrent/Admin/AdminView.swift"))
        XCTAssertNotNil(admin.range(of: pushesAView, options: .regularExpression))
    }
}
