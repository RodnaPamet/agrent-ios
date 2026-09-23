import XCTest
@testable import Agrent

/// The app must decide "no signal" in seconds, not in a minute.
///
/// Found on a real iPhone: Локации sat on a loading spinner after airplane
/// mode was switched on, having loaded instantly from cache moments
/// earlier. Nothing was broken — the cache was populated and correct. The
/// app refused to consult it until `URLSession.shared`'s sixty-second
/// request timeout expired.
///
/// The cause is that airplane mode on iOS commonly leaves Wi-Fi ON, so the
/// device holds a link to a router and believes it has connectivity. There
/// is no fast failure to fall back from.
///
/// A source check, because the value lives in a session configuration with
/// no runtime seam — and because the failure is someone reverting to
/// `URLSession.shared` for convenience, which reads as harmless in a diff.
final class NetworkTimeoutTests: XCTestCase {

    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent(
            "Agrent/API/APIClient.swift"), encoding: .utf8)) ?? ""
    }

    func testTheSourceIsActuallyRead() {
        XCTAssertTrue(source.contains("actor APIClient") || source.contains("APIClient"),
                      "read the wrong file")
        XCTAssertFalse(source.isEmpty)
    }

    /// Long enough for a poor rural connection, short enough that a farmer
    /// reads it as "no signal" rather than "broken".
    func testTheRequestTimeoutIsFieldAppropriate() {
        XCTAssertTrue(source.contains("timeoutIntervalForRequest = 15"),
                      "the request timeout is not set to 15 seconds")
    }

    /// `true` makes URLSession WAIT for connectivity instead of erroring —
    /// which is the exact behaviour that produced the sixty-second spinner,
    /// only unbounded.
    func testItDoesNotWaitForConnectivity() {
        XCTAssertTrue(source.contains("waitsForConnectivity = false"),
                      "waitsForConnectivity must be explicitly false")
    }

    /// The regression: reverting to the shared session silently restores
    /// the 60-second default. Both remaining call sites must use the
    /// app's own session.
    func testNoCallSiteUsesTheSharedSession() {
        XCTAssertFalse(source.contains("URLSession.shared.data"),
                       "a call site is back on URLSession.shared")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "session.data(for: req)").count - 1, 2,
            "positive control: the app's own session is used by both call sites")
    }
}
