import XCTest
@testable import Agrent

/// Every screen that reads a cached list must say how old it is.
///
/// ── Why this is a source test and not a behaviour test ──
///
/// The banner is a two-line `if let` at the top of a view body. There is no
/// runtime seam to assert against without hosting each screen, and the
/// failure is not that it renders wrongly — it is that somebody writing a
/// NEW screen does not add it at all. That is what happened: `TrendsView`
/// and `NewsView` shipped without it, and 400 green tests had nothing to
/// say, because the omission is invisible to every one of them.
///
/// An offline run found it in one screenshot. This is the cheap guard that
/// means the next screen does not need one.
final class StaleBannerCoverageTests: XCTestCase {

    /// Views that render a `CachedResource`-backed list to a person.
    ///
    /// Listed by hand, deliberately. Deriving it from "files that mention
    /// CachedResource" would let a new screen opt itself out by using a
    /// store defined elsewhere — which is exactly how `TrendsView` slipped
    /// through, since its loading lives in `TrendsStore`.
    private let screens = [
        "Journal/JournalListView.swift",
        "Exchange/ExchangeView.swift",
        "Tasks/TasksListView.swift",
        "Calculator/CalculatorView.swift",
        "Locations/LocationsView.swift",
        "Locations/ParcelMapView.swift",
        "Trends/TrendsView.swift",
        "Trends/NewsView.swift",
    ]

    private var sourceRoot: URL {
        // Tests run from the built bundle; walk up to the repo.
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()      // Tests/
        url.deleteLastPathComponent()      // repo root
        return url.appendingPathComponent("Agrent")
    }

    func testEveryCachedScreenShowsItsAge() throws {
        var missing: [String] = []
        for screen in screens {
            let url = sourceRoot.appendingPathComponent(screen)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("\(screen) not found — the list is stale, which is its own bug")
                continue
            }
            if !source.contains("StaleBanner") { missing.append(screen) }
        }
        XCTAssertEqual(missing, [], "these render cached data without saying how old it is")
    }

    /// The positive control. If `sourceRoot` were wrong, every file would
    /// read as empty and the assertion above would pass by finding nothing
    /// — a negative from a probe that cannot produce a positive.
    func testTheSourceIsActuallyBeingRead() throws {
        let url = sourceRoot.appendingPathComponent("Journal/JournalListView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("StaleBanner"))
        XCTAssertTrue(source.contains("struct JournalListView"), "read the wrong file")
    }
}
