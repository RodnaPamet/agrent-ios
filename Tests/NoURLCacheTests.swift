import MapKit
import XCTest
@testable import Agrent

/// Nothing the app fetches may land in URLSession's disk cache (#134).
///
/// The regression this holds is quiet by construction: a new session built
/// from `URLSessionConfiguration.default` "for convenience" compiles, works,
/// and silently writes every 2xx GET it makes — staff emails, ЕГН — into
/// `Library/Caches/<bundle>/Cache.db`. Nothing on screen changes. So two
/// layers: the configurations actually in use are asserted at runtime, and
/// the source tree is scanned for any OTHER way to reach a cache-backed
/// session. Every negative has a positive control beside it, because a guard
/// that reads the wrong file or a cache that cannot store anything passes
/// for the wrong reason.
final class NoURLCacheTests: XCTestCase {

    // MARK: - Runtime: the configurations in use

    /// Positive control for everything below: the system default DOES carry
    /// a cache. If Apple ever changes that, "urlCache is nil" stops meaning
    /// we removed it, and this says so.
    func testTheSystemDefaultCarriesACache() {
        XCTAssertNotNil(URLSessionConfiguration.default.urlCache,
                        "control: .default has no cache, so the nil checks prove nothing")
    }

    func testTheSharedConfigurationHasNoCache() {
        let configuration = NoURLCache.configuration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(NoURLCache.session.configuration.urlCache,
                     "the token-exchange / tile session has a cache")
    }

    /// The session every API request goes through — and it must keep the
    /// field timeout `NetworkTimeoutTests` is about while losing the cache.
    func testTheAPISessionHasNoCache() {
        let configuration = APIClient.sessionConfiguration()
        XCTAssertNil(configuration.urlCache, "APIClient's session has a URL cache again")
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
    }

    /// The test host IS the app, so `AgrentApp.init` has already run
    /// `NoURLCache.install()`. This asserts the launch path, not a call the
    /// test made itself.
    func testTheProcessWideCacheIsDisabledAtLaunch() {
        XCTAssertEqual(URLCache.shared.diskCapacity, 0, "URLCache.shared can write to disk")
        XCTAssertEqual(URLCache.shared.memoryCapacity, 0)
    }

    /// Behaviour, not just capacity numbers: a store into the shared cache
    /// must not be readable back. The control does the identical store into
    /// a cache WITH capacity and must read it back — otherwise the nil above
    /// could be this test failing to store anything at all.
    func testTheSharedCacheRefusesToStore() throws {
        let request = URLRequest(url: URL(string: "https://example.invalid/admin/members")!)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        let cached = CachedURLResponse(response: response, data: Data("{}".utf8))

        let control = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, directory: nil)
        control.storeCachedResponse(cached, for: request)
        XCTAssertNotNil(control.cachedResponse(for: request),
                        "control: a cache with capacity did not keep the response")

        URLCache.shared.storeCachedResponse(cached, for: request)
        XCTAssertNil(URLCache.shared.cachedResponse(for: request),
                     "URLCache.shared kept a response")
    }

    // MARK: - Source: no other way in

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Code only: everything from `//` on is dropped, so this file's subject
    /// can be DISCUSSED in a comment (as NoURLCache.swift does at length)
    /// without tripping the guard. Crude — it also truncates a line at a
    /// `https://` literal — but truncation can only hide code, never invent
    /// it, and the positive controls below show it still sees what matters.
    private func code(_ file: URL) -> String {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    private var appSources: [URL] {
        let dir = root.appendingPathComponent("Agrent")
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Each pattern is a way to get a session — or a tile loader — whose
    /// cache nobody chose. `allowed` is where the deliberate one lives.
    private let doors: [(pattern: String, allowed: Set<String>)] = [
        ("URLSessionConfiguration.default", ["NoURLCache.swift"]),
        ("URLSessionConfiguration.ephemeral", []),
        ("URLSessionConfiguration.background", []),
        ("URLSession.shared", []),
        ("URLSession(configuration:", ["NoURLCache.swift", "APIClient.swift"]),
        ("MKTileOverlay(urlTemplate:", []),
    ]

    func testNoSessionOrTileLoaderBypassesNoURLCache() {
        let files = appSources
        // Positive control: the walk found the app, not an empty directory.
        XCTAssertGreaterThan(files.count, 50, "scanned \(files.count) files — wrong root?")

        var hits: [String] = []
        for file in files {
            let body = code(file)
            for door in doors where body.contains(door.pattern)
                && !door.allowed.contains(file.lastPathComponent) {
                hits.append("\(file.lastPathComponent): \(door.pattern)")
            }
        }
        XCTAssertEqual(hits, [], "a session or tile overlay that does not go through NoURLCache")
    }

    /// Positive control for the scanner: the deliberate uses ARE seen, in
    /// code, after comment stripping. Without this a stripping bug that
    /// emptied every file would pass the guard above.
    func testTheScannerSeesTheDeliberateUses() {
        let core = code(root.appendingPathComponent("Agrent/Core/NoURLCache.swift"))
        XCTAssertTrue(core.contains("URLSessionConfiguration.default"))
        XCTAssertTrue(core.contains("configuration.urlCache = nil"))
        XCTAssertTrue(core.contains("URLCache.shared.removeAllCachedResponses()"),
                      "the purge of what older builds cached is gone")

        let api = code(root.appendingPathComponent("Agrent/API/APIClient.swift"))
        XCTAssertTrue(api.contains("NoURLCache.configuration()"),
                      "APIClient no longer starts from the no-cache configuration")

        let app = code(root.appendingPathComponent("Agrent/AgrentApp.swift"))
        XCTAssertTrue(app.contains("NoURLCache.install()"), "the launch-time purge is not called")
    }
}
