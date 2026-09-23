import CoreGraphics
import XCTest
@testable import Agrent

/// The `·` separator is the bug these exist for. Five screens built a subtitle
/// as `Text(crop); Text("·"); Text(area)`, which reads as one line and speaks
/// as three stops with "middle dot" in the middle. `children: .combine` does
/// not fix it — it concatenates the rendered text, separator included.
final class A11ySentenceTests: XCTestCase {

    func testJoinsWithCommasAndEndsWithAStop() {
        XCTAssertEqual(
            A11y.sentence(["Парцел 3", "Пшеница", "12,4 хектара"]),
            "Парцел 3, Пшеница, 12,4 хектара."
        )
    }

    /// The whole point: no separator character survives into speech.
    func testNoMiddleDotCanReachTheLabel() {
        let label = A11y.sentence(["Пшеница", "12,4 хектара", "под аренда"])
        XCTAssertFalse(label.contains("·"))
    }

    func testNilsAndBlanksAreDropped() {
        XCTAssertEqual(A11y.sentence(["Парцел", nil, "", "   ", "Угар"]), "Парцел, Угар.")
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(A11y.sentence([]), "")
        XCTAssertEqual(A11y.sentence([nil, "  "]), "")
    }

    /// A value that already ends in a stop must not collect a second one.
    func testExistingFullStopIsNotDoubled() {
        XCTAssertEqual(A11y.sentence(["Няма очертание."]), "Няма очертание.")
    }
}
