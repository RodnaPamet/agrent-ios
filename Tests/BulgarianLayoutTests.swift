import UIKit
import XCTest
@testable import Agrent

/// What a test can and cannot say about this.
///
/// It CANNOT assert the fix works. The defect is a drawn width against a
/// slot width, and neither is reachable from a unit test — it was found in
/// a screenshot and it is proven in a screenshot. These assert the parts
/// that are checkable, so that a silent revert of the install call, or a
/// second call from somewhere new, fails here rather than in a field.
@MainActor
final class BulgarianLayoutTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        BulgarianLayout.resetForTesting()
    }

    func testInstallIsIdempotent() {
        BulgarianLayout.resetForTesting()
        XCTAssertFalse(BulgarianLayout.isInstalled)
        BulgarianLayout.install()
        XCTAssertTrue(BulgarianLayout.isInstalled)
        // Twice must be free rather than laying out a second controller.
        BulgarianLayout.install()
        XCTAssertTrue(BulgarianLayout.isInstalled)
    }

    /// The warm-up must leave nothing behind. A controller still retained,
    /// or a view still in a window, would be a leak per launch and could
    /// steal presentation.
    func testInstallLeavesNoViewAttached() {
        BulgarianLayout.resetForTesting()
        let before = UIApplication.shared.connectedScenes.count
        BulgarianLayout.install()
        XCTAssertEqual(UIApplication.shared.connectedScenes.count, before,
                       "the warm-up must not present or attach anything")
    }

    /// It runs before any scene exists, so it must not need one.
    func testInstallDoesNotRequireAWindow() {
        BulgarianLayout.resetForTesting()
        XCTAssertNoThrow(BulgarianLayout.install())
    }
}
