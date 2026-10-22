import XCTest
@testable import Agrent

/// «Версия» in Профил (#393): the build named as TestFlight names it.
final class AppVersionTests: XCTestCase {
    func testTheBuildIsNamedAsTestFlightNamesIt() {
        XCTAssertEqual(AppVersion.text(short: "0.1.0", build: "5.1"), "0.1.0 (5.1)")
    }

    func testAMissingBuildLeavesTheVersion() {
        XCTAssertEqual(AppVersion.text(short: "0.1.0", build: nil), "0.1.0")
        XCTAssertEqual(AppVersion.text(short: "0.1.0", build: " "), "0.1.0")
    }

    func testNoVersionIsNoRow() {
        XCTAssertNil(AppVersion.text(short: nil, build: "5.1"))
        XCTAssertNil(AppVersion.text(short: "", build: "5.1"))
    }

    /// The test host is a real build, so it has a version to show.
    func testThisBuildHasOne() {
        XCTAssertNotNil(AppVersion.current)
    }
}
