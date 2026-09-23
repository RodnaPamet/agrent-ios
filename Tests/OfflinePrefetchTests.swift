import XCTest
@testable import Agrent

/// The catalogue must be fetched BEFORE the field, not in it.
///
/// Found on a real phone: offline, the spray sheet's product picker was
/// empty on a device that had never opened the sheet while online.
/// `ParcelOperationSheet` fetches products in its own `.task`, and
/// `CachedResource` writes the cache only after a successful fetch — so
/// the data was fetched at the exact moment signal is least likely.
///
/// This is a source check for the same reason the `StaleBanner` one is:
/// the failure is that somebody deletes the warm call or adds a new piece
/// of field-critical reference data without warming it, and neither is
/// visible to a runtime assertion.
final class OfflinePrefetchTests: XCTestCase {

    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent(
            "Agrent/Core/OfflinePrefetch.swift"), encoding: .utf8)) ?? ""
    }

    /// Everything the WRITE path depends on. The first version warmed only
    /// products and units, reasoning that locations and parcels arrive via
    /// ordinary navigation — true of a phone already used online, false of
    /// a fresh install taken straight into a field, which is what the
    /// owner did.
    func testItWarmsEverythingTheSprayPathNeeds() {
        for path in ["listPath", "parcelsPath", "itemsPath", "rateUnitsPath"] {
            XCTAssertTrue(source.contains(path), "\(path) is not prefetched")
        }
    }

    /// Positive control: if the path were wrong the file would read empty
    /// and both assertions above would pass by finding nothing.
    func testTheSourceIsActuallyRead() {
        XCTAssertTrue(source.contains("enum OfflinePrefetch"), "read the wrong file")
        XCTAssertFalse(source.isEmpty)
    }

    /// It must be CALLED, not merely defined. A prefetch nobody invokes is
    /// the same as no prefetch, and reads as done in a diff.
    func testItIsCalledOnLaunchAndOnForeground() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = (try? String(contentsOf: url.appendingPathComponent(
            "Agrent/AgrentApp.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(app.contains("struct MainTabView"), "positive control")
        let calls = app.components(separatedBy: "OfflinePrefetch.warm()").count - 1
        XCTAssertEqual(calls, 2, "expected a warm on launch and one on foreground")
    }
}
