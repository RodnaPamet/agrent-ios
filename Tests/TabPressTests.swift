import UIKit
import XCTest
@testable import Agrent

/// A press the bottom bar took and did not act on is finished by the app
/// (agrent-ios#305): what counts as such a press, which icon it was on, and
/// what finishing it does to the router. The defect itself is iOS 27.0.1's
/// and was measured on a phone; nothing here can reproduce it.
@MainActor
final class TabPressTests: XCTestCase {

    private let bar: [AppSurface] = [.journal, .calculator, .exchange, .locations, .tasks]

    private func press(writesBefore: Int = 3) -> TabPress {
        TabPress(index: 2, writesBefore: writesBefore, began: 100, start: CGPoint(x: 214, y: 839))
    }

    // MARK: - What a tap is

    /// The presses measured on the phone: 65–115 ms, lifted where they landed.
    func testAShortPressLiftedInPlaceIsATap() {
        XCTAssertTrue(press().isTap(endingAt: CGPoint(x: 214, y: 839), time: 100.065))
        XCTAssertTrue(press().isTap(endingAt: CGPoint(x: 219, y: 843), time: 100.115))
    }

    /// A slide along the bar is the bar's own gesture, and it answers those.
    func testASlideToAnotherIconIsNotATap() {
        XCTAssertFalse(press().isTap(endingAt: CGPoint(x: 276, y: 839), time: 100.2))
    }

    func testAHoldIsNotATap() {
        XCTAssertFalse(press().isTap(endingAt: CGPoint(x: 214, y: 839), time: 100.6))
    }

    // MARK: - Whether the bar answered

    func testAPressTheBarWroteForIsAnswered() {
        XCTAssertFalse(press(writesBefore: 3).isUnanswered(writesNow: 4))
    }

    func testAPressTheBarWroteNothingForIsTheAppsToFinish() {
        XCTAssertTrue(press(writesBefore: 3).isUnanswered(writesNow: 3))
    }

    // MARK: - The router

    func testTheBarsWritesAreCountedAndTheAppsAreNot() {
        let router = AppRouter(bar: bar)
        router.tab = .exchange
        router.tab = .tasks
        XCTAssertEqual(router.selectionWrites, 2)
        router.finishPress(on: .journal)
        XCTAssertEqual(router.selectionWrites, 2, "a press the app finished read as the bar's answer")
    }

    func testFinishingAPressSelectsItsTab() {
        let router = AppRouter(bar: bar)
        router.finishPress(on: .exchange)
        XCTAssertEqual(router.tab, .exchange)
    }

    /// A press on the tab already open is a re-tap, whoever finishes it.
    func testFinishingAPressOnTheOpenTabPopsIt() {
        let router = AppRouter(bar: bar)
        router.tab = .exchange
        router.paths[.exchange] = NavigationPathFixture.one
        router.finishPress(on: .exchange)
        XCTAssertNil(router.paths[.exchange])
    }

    /// One press is one selection. The bar answering late must not arrive as
    /// a re-tap and pop the screens of the tab just opened.
    func testTheBarAnsweringLateIsNotARetap() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let router = AppRouter(bar: bar, now: { clock })
        router.paths[.exchange] = NavigationPathFixture.one
        router.finishPress(on: .exchange)
        clock += 0.2
        router.tab = .exchange
        XCTAssertEqual(router.paths[.exchange], NavigationPathFixture.one, "the late answer popped the tab")
        XCTAssertEqual(router.tab, .exchange)
    }

    /// The late answer is forgiven once: the next press on the same tab is
    /// the person's own re-tap.
    func testAPressAfterTheLateAnswerIsARetapAgain() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let router = AppRouter(bar: bar, now: { clock })
        router.paths[.exchange] = NavigationPathFixture.one
        router.finishPress(on: .exchange)
        clock += 0.2
        router.tab = .exchange
        clock += 0.2
        router.tab = .exchange
        XCTAssertNil(router.paths[.exchange])
    }

    /// And a re-tap long after a finished press is a re-tap.
    func testARetapWellAfterAFinishedPressStillPops() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let router = AppRouter(bar: bar, now: { clock })
        router.finishPress(on: .exchange)
        router.paths[.exchange] = NavigationPathFixture.one
        clock += AppRouter.latePress + 0.5
        router.tab = .exchange
        XCTAssertNil(router.paths[.exchange])
    }

    /// Another tab chosen in between ends the forgiveness.
    func testChoosingAnotherTabEndsTheLateAnswersGrace() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let router = AppRouter(bar: bar, now: { clock })
        router.finishPress(on: .exchange)
        clock += 0.1
        router.tab = .tasks
        router.tab = .exchange
        router.paths[.exchange] = NavigationPathFixture.one
        clock += 0.1
        router.tab = .exchange
        XCTAssertNil(router.paths[.exchange], "a real re-tap was taken for a late answer")
    }

    func testAPressOnATabThatLeftTheBarIsDropped() {
        let router = AppRouter(bar: [.journal, .calculator])
        router.finishPress(on: .exchange)
        XCTAssertEqual(router.tab, .journal)
    }

    // MARK: - Which icon

    private final class Icon: UIControl {}

    /// A view holds its superview weakly: the bars built below are kept here,
    /// or their icons would be orphans by the time they are asked about.
    private var bars: [UITabBar] = []

    /// A bar shaped like the system's: the icons side by side in one
    /// container inside the `UITabBar`, each with a word in it.
    private func barOfIcons(_ count: Int, addedInOrder order: [Int]? = nil) -> [Icon] {
        let tabBar = UITabBar(frame: CGRect(x: 0, y: 791, width: 402, height: 83))
        bars.append(tabBar)
        let row = UIView(frame: CGRect(x: 21, y: 0, width: 360, height: 62))
        tabBar.addSubview(row)
        let icons = (0..<count).map { index -> Icon in
            let icon = Icon(frame: CGRect(x: 4 + index * 70, y: 4, width: 68, height: 54))
            icon.addSubview(UILabel(frame: CGRect(x: 20, y: 35, width: 27, height: 12)))
            return icon
        }
        for index in order ?? Array(0..<count) { row.addSubview(icons[index]) }
        return icons
    }

    func testAnIconsPlaceIsItsPlaceFromTheLeft() {
        let icons = barOfIcons(5)
        XCTAssertEqual(TabBarPressObserver.iconIndex(of: icons[0], among: 5), 0)
        XCTAssertEqual(TabBarPressObserver.iconIndex(of: icons[3], among: 5), 3)
    }

    /// The finger lands on the word under the picture as often as on the icon.
    func testATouchOnAnIconsWordIsATouchOnTheIcon() {
        let icons = barOfIcons(5)
        XCTAssertEqual(TabBarPressObserver.iconIndex(of: icons[2].subviews[0], among: 5), 2)
    }

    /// By position, not by the order the views were added in.
    func testThePlaceIsReadFromTheScreenNotTheViewOrder() {
        let icons = barOfIcons(5, addedInOrder: [4, 2, 0, 3, 1])
        XCTAssertEqual(TabBarPressObserver.iconIndex(of: icons[1], among: 5), 1)
        XCTAssertEqual(TabBarPressObserver.iconIndex(of: icons[4], among: 5), 4)
    }

    /// A bar that does not have one icon per tab cannot be read, and then no
    /// press is finished — never a guess at which tab.
    func testABarWithAnotherNumberOfIconsYieldsNone() {
        let icons = barOfIcons(4)
        XCTAssertNil(TabBarPressObserver.iconIndex(of: icons[1], among: 5))
    }

    func testFiveControlsThatAreNotOnATabBarAreNotIcons() {
        let row = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 62))
        let controls = (0..<5).map { Icon(frame: CGRect(x: $0 * 70, y: 0, width: 68, height: 54)) }
        controls.forEach(row.addSubview)
        XCTAssertNil(TabBarPressObserver.iconIndex(of: controls[2], among: 5))
    }

    func testNoViewIsNoIcon() {
        XCTAssertNil(TabBarPressObserver.iconIndex(of: nil, among: 5))
    }
}

import SwiftUI

private enum NavigationPathFixture {
    @MainActor static let one = NavigationPath([AppRoute.conversation(threadID: "t1", commodity: "wheat")])
}
