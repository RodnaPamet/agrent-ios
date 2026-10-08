import SwiftUI
import XCTest
@testable import Agrent

/// Every surface the app menu can present has a way out (#119, #108).
///
/// Read from the source, because the property is "this screen's toolbar,
/// inside its own NavigationStack, draws «Затвори» when a flag is set" — and
/// hosting nine network-backed screens in a sheet to look for a button would
/// test the fixtures more than the wiring. Each probe has a positive control,
/// so a moved file fails rather than passes.
final class MenuSheetCloseTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Where each surface's root view lives. A SWITCH, not a dictionary, so
    /// a tenth `AppSurface` does not compile until somebody says where its
    /// screen is — and is then held to the same rule as the other nine.
    private func file(for surface: AppSurface) -> String {
        switch surface {
        case .journal: "Agrent/Journal/JournalListView.swift"
        case .calculator: "Agrent/Calculator/CalculatorView.swift"
        case .exchange: "Agrent/Exchange/ExchangeView.swift"
        case .locations: "Agrent/Locations/LocationsView.swift"
        case .tasks: "Agrent/Tasks/TasksListView.swift"
        case .trends: "Agrent/Trends/TrendsView.swift"
        case .news: "Agrent/Trends/NewsView.swift"
        case .farmRisk: "Agrent/FarmRisk/FarmRiskView.swift"
        case .dashboard: "Agrent/Dashboard/DashboardView.swift"
        }
    }

    /// The menu marks what it presents. Without this line the flag is never
    /// set and every surface below passes while drawing nothing.
    ///
    /// And it clears the tab's surface (#194): the menu sits ON a tab, so a
    /// sheet that kept it would push onto that tab's path in the router.
    func testTheMenuSheetSaysItIsTheMenus() throws {
        let menu = try source("Agrent/Design/AppMenu.swift")
        guard let start = menu.range(of: ".sheet(item: $presented) {") else {
            return XCTFail("the menu no longer presents its surfaces by .sheet(item: $presented)")
        }
        let sheet = String(menu[start.lowerBound...].prefix(240))
        XCTAssertTrue(sheet.contains(#".environment(\.presentedFromMenu, true)"#))
        XCTAssertTrue(sheet.contains(#".environment(\.routedSurface, nil)"#),
                      "a menu sheet would push onto the router's path for its tab")
    }

    /// The button itself: in the cancellation slot, named aloud, and behind
    /// the flag — so a surface on the TAB BAR draws none.
    func testTheWayOutIsDrawnOnlyForTheMenu() throws {
        let menu = try source("Agrent/Design/AppMenu.swift")
        guard let start = menu.range(of: "private struct MenuSheetClose: ViewModifier") else {
            return XCTFail("MenuSheetClose moved — this test no longer sees the button")
        }
        let modifier = String(menu[start.lowerBound...])
        XCTAssertTrue(modifier.contains("if presentedFromMenu {"))
        XCTAssertTrue(modifier.contains("placement: .topBarTrailing"))
        XCTAssertTrue(modifier.contains(#"Button("Затвори") { dismiss() }"#))
        XCTAssertTrue(modifier.contains(".accessibilityInputLabels(A11y.Spoken.close)"))
        // Both `appMenu` overloads carry it, so a screen with a menu has it.
        XCTAssertEqual(menu.components(separatedBy: ".closeWhenPresentedFromMenu()").count - 1, 2,
                       "each appMenu overload applies the way out exactly once")
    }

    /// Nothing sets the flag by default, which is what keeps a tab root
    /// free of a «Затвори» that would dismiss nothing.
    func testATabRootIsNotMenuPresented() {
        XCTAssertFalse(EnvironmentValues().presentedFromMenu)
    }

    /// THE REGRESSION. Every surface — any of them can be moved off the bar
    /// — reaches the button through `.appMenu()` or directly, and none keeps
    /// an unconditional «Затвори» of its own, which as a tab root is a button
    /// that does nothing.
    func testEverySurfaceHasAWayOutFromTheMenu() throws {
        XCTAssertEqual(AppSurface.allCases.count, 9, "positive control: the nine surfaces")
        for surface in AppSurface.allCases {
            let path = file(for: surface)
            let text = try source(path)
            XCTAssertTrue(text.contains("struct \(String(describing: rootType(surface)))"),
                          "positive control: \(path) is not \(surface)'s screen")
            XCTAssertTrue(text.contains(".appMenu()") || text.contains(".closeWhenPresentedFromMenu()"),
                          "\(surface.label) has no way out when the menu presents it")
            XCTAssertFalse(text.contains("placement: .cancellationAction"),
                           "\(surface.label) draws its own «Затвори» — dead on the tab bar")
        }
    }

    /// The screen's type as a symbol rather than a string, so a rename
    /// breaks the build here instead of silently re-pointing the control.
    private func rootType(_ surface: AppSurface) -> Any.Type {
        switch surface {
        case .journal: JournalListView.self
        case .calculator: CalculatorView.self
        case .exchange: ExchangeView.self
        case .locations: LocationsView.self
        case .tasks: TasksListView.self
        case .trends: TrendsView.self
        case .news: NewsView.self
        case .farmRisk: FarmRiskView.self
        case .dashboard: DashboardView.self
        }
    }
}
