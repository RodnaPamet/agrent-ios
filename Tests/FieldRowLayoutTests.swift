import SwiftUI
import UIKit
import XCTest
@testable import Agrent

/// A `FieldRow` is as high as its title, and its title comes before its field.
///
/// On Админ → «Цени» the fertiliser names were wrapped to two lines beside
/// their fields — «Уреа (карбамид), €/т», with half the row empty — and the
/// row stayed ONE line high, so «€/т» was drawn over the «Източник…» note
/// under it (owner, on the phone, 2026-10-13). The crops above are short, and
/// the screenshot suite stopped at the fold.
///
/// Measured through the real row — hosted in a form, in a window at a
/// phone's width, in the simulator this suite runs in.
@MainActor
final class FieldRowLayoutTests: XCTestCase {

    @MainActor private final class Measured {
        var row = CGSize.zero
        var field = CGSize.zero
    }

    /// One line at the row's full width, two beside any field worth typing in.
    private static let diesel = "Нафта (дизелово гориво), €/л"

    private func probe(_ size: ReferenceWritableKeyPath<Measured, CGSize>, into measured: Measured) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { measured[keyPath: size] = proxy.size }
                .onChange(of: proxy.size) { _, new in measured[keyPath: size] = new }
        }
    }

    /// `title`'s row and its field, as a form lays them out: over a note when
    /// `inStack`, as on «Цени», and as a form row of its own otherwise.
    private func layout(_ title: String, size: DynamicTypeSize = .large, width: CGFloat = 402,
                        inStack: Bool = true) -> Measured {
        let measured = Measured()
        let row = FieldRow(title) {
            TextField("0", text: .constant(""), prompt: .fieldPrompt("0"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .background { probe(\.field, into: measured) }
        }
        .background { probe(\.row, into: measured) }
        let root = PageForm {
            Section {
                if inStack {
                    VStack(alignment: .leading, spacing: 6) {
                        row
                        Text("Източник: 1395,00 €/1000 л, 6 октомври").font(.footnote)
                    }
                } else {
                    row
                }
            }
        }
        .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<10 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return measured
    }

    /// The lines `title` takes in the width its field leaves it, and the
    /// height of one. The row's spacing is not taken off, so the count is
    /// never more than what is drawn.
    private func titleLines(_ title: String, beside measured: Measured) -> (count: Int, height: CGFloat) {
        let font = UIFont.preferredFont(forTextStyle: .body,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let room = CGSize(width: measured.row.width - measured.field.width, height: .greatestFiniteMagnitude)
        let needs = (title as NSString).boundingRect(with: room, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: font], context: nil).height
        return (Int((needs / font.lineHeight).rounded()), font.lineHeight)
    }

    func testATitleOfTwoLinesMakesTheRowTwoLinesHigh() {
        let measured = layout(Self.diesel)
        XCTAssertGreaterThan(measured.row.height, 0, "nothing was measured — the probes are not being laid out")
        let lines = titleLines(Self.diesel, beside: measured)
        XCTAssertEqual(lines.count, 2, "«Нафта…» was meant to take two lines beside its field")
        XCTAssertGreaterThanOrEqual(measured.row.height, CGFloat(lines.count) * lines.height - 1,
                                    "the title's second line has no room and is drawn over what follows the row")
    }

    /// The same as a form row of its own, where the second line is drawn
    /// over the next row instead of a note.
    func testTheSameAsAFormRowOfItsOwn() {
        let measured = layout(Self.diesel, inStack: false)
        let lines = titleLines(Self.diesel, beside: measured)
        XCTAssertEqual(lines.count, 2)
        XCTAssertGreaterThanOrEqual(measured.row.height, CGFloat(lines.count) * lines.height - 1)
    }

    /// The title comes first: the field takes what a name leaves, so one that
    /// fits beside its field is not wrapped to give the field half the row.
    func testTheFieldTakesWhatTheTitleLeaves() {
        let short = layout("Тонове")
        let urea = layout("Уреа (карбамид), €/т")
        XCTAssertEqual(titleLines("Уреа (карбамид), €/т", beside: urea).count, 1,
                       "«Уреа (карбамид), €/т» is on two lines in a row \(urea.row.width) wide, "
                       + "beside a field \(urea.field.width) wide")
        XCTAssertEqual(urea.row.height, short.row.height, accuracy: 1)
        XCTAssertLessThan(urea.field.width, short.field.width - 40,
                          "the field is as wide beside a long title as beside a short one")
    }

    /// However long the title, the field keeps room for a price.
    func testTheFieldKeepsRoomToTypeIn() {
        let measured = layout("Нафта (дизелово гориво), евро за хиляда литра")
        XCTAssertGreaterThanOrEqual(measured.field.width, 80)
    }

    /// At the accessibility sizes the field goes under its title at the
    /// row's full width, as `LabeledContent` put it.
    func testAtAnAccessibilitySizeTheFieldGoesUnderItsTitle() {
        let measured = layout("Тонове", size: .accessibility3)
        XCTAssertEqual(measured.field.width, measured.row.width, accuracy: 1)
        XCTAssertGreaterThan(measured.row.height, measured.field.height + 10)
    }
}
