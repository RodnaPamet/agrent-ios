import XCTest
@testable import Agrent

/// The way back from a pushed screen is the arrow lower left (`FloatingBack`,
/// owner 2026-11-19), on every screen that is pushed.
final class FloatingBackTests: XCTestCase {

    // MARK: - The swipe back

    /// The edge swipe stays on with the system's button hidden: allowed with
    /// a screen to go back to, refused at a stack's root and while a save
    /// holds it off.
    @MainActor func testTheSwipeBackFollowsTheStackAndTheHolds() {
        let before = SwipeBack.holds
        defer { SwipeBack.holds = before }
        SwipeBack.holds = 0
        XCTAssertFalse(SwipeBack.allows(depth: 1), "a root has nothing to go back to")
        XCTAssertFalse(SwipeBack.allows(depth: 0))
        XCTAssertTrue(SwipeBack.allows(depth: 2), "positive control: a pushed screen swipes back")
        SwipeBack.holds = 1
        XCTAssertFalse(SwipeBack.allows(depth: 2), "a save under way holds the swipe off")
    }

    // MARK: - Every push site

    struct Site {
        let file: String
        let destination: String
    }

    /// Each place a screen is pushed — `navigationDestination(for:)` and a
    /// `NavigationLink` that pushes a view — with the closure that builds the
    /// screen.
    static func pushSites(in raw: String, file: String) -> [Site] {
        let source = SignOutHygieneTests.code(raw)
        var sites: [Site] = []
        for marker in ["navigationDestination(for:", "NavigationLink {"] {
            var searchStart = source.startIndex
            while let hit = source.range(of: marker, range: searchStart..<source.endIndex) {
                searchStart = hit.upperBound
                guard let body = closure(after: hit.lowerBound, in: source) else { continue }
                sites.append(Site(file: file, destination: body))
            }
        }
        return sites
    }

    /// The first `{ … }` from `start`, braces balanced.
    static func closure(after start: String.Index, in source: String) -> String? {
        guard let open = source[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func appSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testEveryPushedScreenHasTheArrow() throws {
        let sites = try appSources().flatMap { Self.pushSites(in: $0.text, file: $0.name) }
        // Floor: 30 push sites when the arrow landed. A selector that stopped
        // matching would otherwise pass over nothing.
        XCTAssertGreaterThanOrEqual(sites.count, 25, "positive control: the push sites were not found")
        XCTAssertTrue(sites.contains { $0.file == "RoutedStack.swift" }, "positive control: the routed destination")
        let missing = sites.filter { !$0.destination.contains(".floatingBack(") }
        XCTAssertEqual(missing.map(\.file), [],
                       "a screen pushed here keeps the system's back button top left — apply `.floatingBack()`")
    }

    /// The detector itself: a push with the arrow passes, one without fails,
    /// and a push in a comment is not a push.
    func testTheDetectorSeesAMissingArrow() {
        let with = "x.navigationDestination(for: A.self) { A($0).floatingBack() }"
        let without = "x.navigationDestination(for: A.self) { if ok { A($0) } }\nNavigationLink {\n B()\n} label: { Text(\"b\") }"
        let commented = "// x.navigationDestination(for: A.self) { A($0) }"
        XCTAssertEqual(Self.pushSites(in: with, file: "w").filter { !$0.destination.contains(".floatingBack(") }.count, 0)
        let bare = Self.pushSites(in: without, file: "o")
        XCTAssertEqual(bare.count, 2)
        XCTAssertEqual(bare.filter { !$0.destination.contains(".floatingBack(") }.count, 2)
        XCTAssertTrue(bare[0].destination.hasSuffix("} }"), "the whole closure, nested braces included")
        XCTAssertTrue(Self.pushSites(in: commented, file: "c").isEmpty)
    }

    /// Hiding the system's button anywhere else would leave a screen with no
    /// way back at all.
    func testOnlyTheArrowHidesTheSystemsBackButton() throws {
        let sources = try appSources()
        XCTAssertTrue(sources.contains { $0.name == "FloatingBack.swift" }, "positive control")
        let hiding = sources
            .filter { SignOutHygieneTests.code($0.text).contains("navigationBarBackButtonHidden(") }
            .map(\.name)
        XCTAssertEqual(hiding, ["FloatingBack.swift"])
    }
}
