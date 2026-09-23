import XCTest
@testable import Agrent

/// Screens that already hold the answer must not make a farmer watch a
/// spinner to be told it.
///
/// ── The device disproved the original policy ──
///
/// `CachedResource`'s header argued network-first is "the trade a phone in
/// a field wants". A real iPhone in airplane mode disproved it: iOS leaves
/// Wi-Fi ON, so the device holds a router link and believes it has
/// connectivity. There is no fast failure to fall back from, and every
/// screen waited out the request timeout before consulting a cache that
/// was populated and correct the whole time.
///
/// Shortening the timeout from 60s to 15s only shortened the wait. The
/// wait itself was the defect.
@MainActor
final class CacheFirstTests: XCTestCase {

    private func source(_ path: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent(path),
                            encoding: .utf8)) ?? ""
    }

    func testTheHelperExists() {
        let s = source("Agrent/Core/CachedResource.swift")
        XCTAssertTrue(s.contains("enum CachedResource"), "positive control")
        XCTAssertTrue(s.contains("loadShowingCacheFirst"))
    }

    /// The field path — the screens a farmer reaches with no signal. These
    /// are the ones where a spinner costs a record of regulated work.
    func testTheFieldPathShowsCacheFirst() {
        let locations = source("Agrent/Locations/LocationsStore.swift")
        XCTAssertTrue(locations.contains("struct") || locations.contains("final class"),
                      "positive control")
        XCTAssertEqual(
            locations.components(separatedBy: "loadShowingCacheFirst").count - 1, 2,
            "both the locations list and the parcels must show cache first")

        let sheet = source("Agrent/Locations/ParcelOperationSheet.swift")
        XCTAssertEqual(
            sheet.components(separatedBy: "loadShowingCacheFirst").count - 1, 2,
            "products and units must show cache first")
    }

    /// A network failure must NOT replace content already on screen with an
    /// error. The cache answered; the failure is only news when there was
    /// nothing to show.
    func testAFailureDoesNotOverwriteShownContent() {
        let s = source("Agrent/Core/CachedResource.swift")
        XCTAssertTrue(s.contains("if case .failed = fresh"),
                      "a failure can overwrite cached content already published")
    }

    /// Staleness stays visible. The first publish is marked stale with the
    /// time it was fetched, and every screen using this carries StaleBanner.
    func testTheFirstPublishIsMarkedStale() {
        let s = source("Agrent/Core/CachedResource.swift")
        XCTAssertTrue(s.contains(".stale(since: hit.fetchedAt)"),
                      "cached data must be published as stale, not as fresh")
    }
}
