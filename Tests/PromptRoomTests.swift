import SwiftUI
import UIKit
import XCTest
@testable import Agrent

/// agrent-ios#164: a vertical field's prompt WRAPS with `promptRoom`, where
/// it was cut to «напр. Трети…» at AX5 in «Нов запис».
///
/// Measured through the real field — hosted in a window at a phone's width,
/// in the simulator this suite runs in, not on a device. The prompt of a
/// `TextField(axis: .vertical)` is a `UILabel` that allows any number of
/// lines and is exactly as high as the field; "fits" is that label being as
/// high as its text needs at its own width.
@MainActor
final class PromptRoomTests: XCTestCase {

    private static let example = "напр. Третиране на южния блок"

    /// (height the prompt's label has, height its text needs), or nil when
    /// no label holds the prompt.
    private func promptLabel(size: DynamicTypeSize, width: CGFloat, room: Bool) -> (has: CGFloat, needs: CGFloat)? {
        let field = TextField("Заглавие", text: .constant(""),
                              prompt: .fieldPrompt(Self.example), axis: .vertical)
        let root = PageForm {
            Section(titled: "Заглавие") {
                if room { field.promptRoom(Self.example) } else { field }
            }
        }
        .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // The measured room lands on a later turn of the run loop: the hidden
        // texts report their heights from `onAppear` / `onChange`.
        for _ in 0..<10 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let label = labels(in: window).first(where: { $0.text == Self.example }) else { return nil }
        let needs = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
        return (label.bounds.height, needs)
    }

    private func labels(in view: UIView) -> [UILabel] {
        var found = view.subviews.flatMap { labels(in: $0) }
        if let label = view as? UILabel { found.insert(label, at: 0) }
        return found
    }

    func testAtAX5ThePromptHasTheRoomItNeeds() throws {
        let measured = try XCTUnwrap(promptLabel(size: .accessibility5, width: 402, room: true),
                                     "no UILabel holds the prompt — this check needs a new hook")
        XCTAssertLessThanOrEqual(measured.needs, measured.has + 0.5, "the prompt is cut at AX5")
    }

    /// The control: without `promptRoom` the same field cuts it — the defect
    /// #164 filed, so the test above can fail.
    func testWithoutPromptRoomThePromptIsCut() throws {
        let measured = try XCTUnwrap(promptLabel(size: .accessibility5, width: 402, room: false))
        XCTAssertGreaterThan(measured.needs, measured.has + 0.5)
    }

    /// At the default size the prompt fits on one line, and the room is that
    /// one line — the field is what it was before #164.
    func testAtTheDefaultSizeTheFieldIsOneLine() throws {
        let with = try XCTUnwrap(promptLabel(size: .large, width: 402, room: true))
        let without = try XCTUnwrap(promptLabel(size: .large, width: 402, room: false))
        XCTAssertEqual(with.has, without.has, accuracy: 0.5)
        XCTAssertLessThanOrEqual(with.needs, with.has + 0.5)
    }

    /// A narrower phone needs more lines; the room is measured, not looked
    /// up, so it follows.
    func testOnANarrowPhoneThePromptStillFits() throws {
        let measured = try XCTUnwrap(promptLabel(size: .accessibility5, width: 375, room: true))
        XCTAssertLessThanOrEqual(measured.needs, measured.has + 0.5)
    }
}
