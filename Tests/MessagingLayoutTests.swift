import SwiftUI
import UIKit
import XCTest
@testable import Agrent

/// agrent-ios#124, first half: the SELECTED chip is scrolled fully into view.
///
/// Measured through the real row — SwiftUI's horizontal `ScrollView` is a
/// `UIScrollView` underneath — hosted in a window at a phone's width, in the
/// simulator this suite runs in; not on a device. «Съобщения» is the LAST of
/// the four, so "fully in view" is "the row is scrolled to its end".
@MainActor
final class ExchangeSectionChipRevealTests: XCTestCase {

    private func chipRow(selected: ExchangeView.Tab, width: CGFloat = 402) -> (UIScrollView?, UIWindow) {
        // AX3 forces the chips (see `ExchangeSectionPickerTests`), and makes
        // four of them overflow a phone for certain.
        let root = ExchangeSectionPicker(selection: .constant(selected), unread: 3)
            .padding(.horizontal)
            .environment(\.dynamicTypeSize, .accessibility3)
            .environment(\.locale, Locale(identifier: "bg_BG"))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 300))
        window.rootViewController = host
        window.makeKeyAndVisible()
        // `onAppear` and `scrollTo` land on later turns of the run loop, not
        // inside `layoutIfNeeded`.
        for _ in 0..<5 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return (first(UIScrollView.self, in: host.view), window)
    }

    private func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = first(type, in: sub) { return hit }
        }
        return nil
    }

    /// The bug: «Съобщения» selected and the row left at its start, so the
    /// chip was clipped at the right edge.
    func testTheLastChipWhenSelectedIsScrolledFullyIntoView() throws {
        let (row, window) = chipRow(selected: .messages)
        defer { window.isHidden = true }
        let scroll = try XCTUnwrap(row, "no UIScrollView under the chip row")
        // The row must actually overflow, or this proves nothing.
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width,
                             "the four chips fit — this window proves nothing")
        XCTAssertGreaterThan(scroll.contentOffset.x, 0, "the row never scrolled")
        XCTAssertGreaterThanOrEqual(scroll.contentOffset.x + scroll.bounds.width,
                                    scroll.contentSize.width - 1,
                                    "«Съобщения» is not fully in view")
    }

    /// The control: the first chip selected leaves the row at its start —
    /// the reveal scrolls the least it can, not always to the end.
    func testTheFirstChipWhenSelectedLeavesTheRowAtItsStart() throws {
        let (row, window) = chipRow(selected: .browse)
        defer { window.isHidden = true }
        let scroll = try XCTUnwrap(row, "no UIScrollView under the chip row")
        XCTAssertEqual(scroll.contentOffset.x, 0, accuracy: 0.5)
    }
}

/// agrent-ios#124 at the source level, for what a hosted view cannot show:
/// where the notices live, and what the scrolls ask first.
final class MessagingLayoutSourceTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text between two markers, or nil when either moved.
    private func slice(_ text: String, from start: String, to end: String) -> Substring? {
        guard let a = text.range(of: start),
              let b = text.range(of: end, range: a.upperBound..<text.endIndex)
        else { return nil }
        return text[a.upperBound..<b.lowerBound]
    }

    /// Second half: closed and blocked are NOT pinned above the composer —
    /// at AX5 the blocked sentence took seven lines there and left room for
    /// one message. They live in the scrolling list, after the messages.
    func testTheNoticesScrollWithTheConversation() throws {
        let text = try source("Agrent/Exchange/ConversationView.swift")
        let footer = try XCTUnwrap(slice(text, from: "private var footer: some View",
                                         to: "private var composer"),
                                   "the footer or the composer moved")
        XCTAssertFalse(footer.contains("RefusalNote"), "a state note is pinned above the composer again")
        XCTAssertFalse(footer.contains("blockedNotice"))
        XCTAssertFalse(footer.contains("notices"))

        let list = try XCTUnwrap(slice(text, from: "private var messageList: some View",
                                       to: ".defaultScrollAnchor(.bottom)"),
                                 "the message list moved")
        let messages = try XCTUnwrap(list.range(of: "ForEach(store.messages)"))
        let notices = try XCTUnwrap(list.range(of: "\n                    notices\n"),
                                    "the notices are not in the scrolling list")
        XCTAssertLessThan(messages.lowerBound, notices.lowerBound, "the notices belong AFTER the messages")

        let block = try XCTUnwrap(slice(text, from: "private var notices: some View",
                                        to: "// MARK: - Footer"),
                                  "the notices moved")
        XCTAssertTrue(block.contains("MessagingPolicy.blockedNotice(role: store.role)"))
        XCTAssertTrue(block.contains("Този разговор е затворен."))
    }

    /// Scrolling to "the newest" goes past the notices, so a reply never
    /// parks «Блокирали сте…» just under the composer; and every animated
    /// scroll asks Reduce Motion first.
    func testTheConversationScrollsToItsEndPastTheNotices() throws {
        let text = try source("Agrent/Exchange/ConversationView.swift")
        XCTAssertTrue(text.contains("proxy.scrollTo(Self.end, anchor: .bottom)"))
        XCTAssertFalse(text.contains("proxy.scrollTo(new, anchor: .bottom)"))
        XCTAssertTrue(text.contains("animated && !reduceMotion"))
    }

    /// First half, the parts the hosted test does not reach: the reveal
    /// follows the selection and the count, animates only without Reduce
    /// Motion, and uses nothing from iOS 18.
    func testTheChipRowRevealsTheSelection() throws {
        let text = try source("Agrent/Exchange/ExchangeView.swift")
        let row = try XCTUnwrap(slice(text, from: "struct ExchangeSectionPicker: View",
                                      to: "private func chip("),
                                "the section picker moved")
        XCTAssertTrue(row.contains("ScrollViewReader"))
        XCTAssertTrue(row.contains("chip(tab).id(tab)"))
        XCTAssertTrue(row.contains(".onAppear { reveal(selection"))
        XCTAssertTrue(row.contains(".onChange(of: selection)"))
        XCTAssertTrue(row.contains(".onChange(of: unread)"))
        XCTAssertTrue(row.contains("proxy.scrollTo(tab, anchor: nil)"))
        XCTAssertTrue(row.contains("animated && !reduceMotion"))
        XCTAssertFalse(row.contains("onScrollGeometryChange"), "iOS 18")
        XCTAssertFalse(row.contains("ScrollPosition("), "iOS 18")
    }
}
