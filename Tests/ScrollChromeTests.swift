import XCTest
@testable import Agrent

/// The corner buttons step aside while a page scrolls down and come back on
/// the way up (owner, 2026-11-26).
@MainActor
final class ScrollChromeTests: XCTestCase {
    private func chrome() -> ScrollChrome {
        let c = ScrollChrome.shared
        c.reset()
        return c
    }

    func testScrollingDownHidesAndScrollingUpShows() throws {
        try XCTSkipIf(ScrollChrome.assistiveTechnologyRunning)
        let c = chrome()
        c.scrolled(to: 100, topInset: 0, byUser: true)
        c.scrolled(to: 140, topInset: 0, byUser: true)
        XCTAssertTrue(c.hidden)
        c.scrolled(to: 120, topInset: 0, byUser: true)
        XCTAssertFalse(c.hidden)
    }

    /// A finger moves the page a few points per frame: the distance counts
    /// from where the direction turned, not frame to frame.
    func testADragInSmallStepsHidesAndAShortWayBackShows() throws {
        try XCTSkipIf(ScrollChrome.assistiveTechnologyRunning)
        let c = chrome()
        for y in stride(from: 100.0, through: 160.0, by: 3) {
            c.scrolled(to: y, topInset: 0, byUser: true)
        }
        XCTAssertTrue(c.hidden, "60 points down in 3-point frames")
        for y in stride(from: 157.0, through: 145.0, by: -3) {
            c.scrolled(to: y, topInset: 0, byUser: true)
        }
        XCTAssertFalse(c.hidden, "15 points back up, still far from the top")
        for y in stride(from: 148.0, through: 154.0, by: 3) {
            c.scrolled(to: y, topInset: 0, byUser: true)
        }
        XCTAssertFalse(c.hidden, "9 points down again is not yet a direction")
    }

    func testAFewPointsOfJitterChangeNothing() throws {
        try XCTSkipIf(ScrollChrome.assistiveTechnologyRunning)
        let c = chrome()
        c.scrolled(to: 200, topInset: 0, byUser: true)
        c.scrolled(to: 205, topInset: 0, byUser: true)
        XCTAssertFalse(c.hidden)
    }

    func testContentLoadingMovesTheOffsetWithoutHiding() throws {
        try XCTSkipIf(ScrollChrome.assistiveTechnologyRunning)
        let c = chrome()
        c.scrolled(to: 100, topInset: 0, byUser: false)
        c.scrolled(to: 400, topInset: 0, byUser: false)
        XCTAssertFalse(c.hidden)
    }

    func testTheTopOfThePageAlwaysShowsThem() throws {
        try XCTSkipIf(ScrollChrome.assistiveTechnologyRunning)
        let c = chrome()
        c.scrolled(to: 100, topInset: 0, byUser: true)
        c.scrolled(to: 300, topInset: 0, byUser: true)
        XCTAssertTrue(c.hidden)
        // A List's offset starts at minus its top inset.
        c.scrolled(to: -60, topInset: 100, byUser: true)
        XCTAssertFalse(c.hidden)
    }

    func testANewScreenStartsWithThemShown() throws {
        try XCTSkipIf(ScrollChrome.assistiveTechnologyRunning)
        let c = chrome()
        c.scrolled(to: 100, topInset: 0, byUser: true)
        c.scrolled(to: 300, topInset: 0, byUser: true)
        XCTAssertTrue(c.hidden)
        c.reset()
        XCTAssertFalse(c.hidden)
    }

    /// Every corner button and every screen is wired, read from the source:
    /// the behaviour lives in one modifier, so the call sites are the risk.
    func testTheCornersAndTheScreensAreWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let floating = try read("Agrent/Design/FloatingBack.swift")
        XCTAssertTrue(floating.contains(".hidesWhileScrollingDown()"), "the back/close corner")
        XCTAssertEqual(floating.components(separatedBy: ".reportsScrollDirection()").count - 1, 2,
                       "a pushed screen and a sheet's first page each report their scrolling")
        // On the button and BEFORE the sheets: hiding removes the view, so
        // after them it would take the conversation and the sheets with it.
        let launcher = try read("Agrent/Assistant/AssistantLauncher.swift")
        let hide = try XCTUnwrap(launcher.range(of: ".hidesWhileScrollingDown()"))
        let sheet = try XCTUnwrap(launcher.range(of: ".sheet(isPresented: $open"))
        XCTAssertLessThan(hide.lowerBound, sheet.lowerBound)
        XCTAssertTrue(try read("Agrent/Tabs/RoutedStack.swift").contains("root.reportsScrollDirection()"))
    }
}
