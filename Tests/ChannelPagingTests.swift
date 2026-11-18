import XCTest
@testable import Agrent

/// #677 — the channel feed and thread keep what the reader has paged to,
/// and never leave a hole nothing pages into.
final class ChannelPagingTests: XCTestCase {

    private func post(_ id: String, _ minute: Double) -> ChannelPost {
        ChannelPost(id: id, authorUserId: "u", body: "Публикация \(id)", kind: "POST",
                    createdAt: Date(timeIntervalSince1970: 1_763_000_000 + minute * 60),
                    deleted: false, resolvedAt: nil, replyCount: 0, author: nil)
    }

    // MARK: - The newest page over the feed (newest first)

    func testAPageThatDoesNotReachTheHeldListLeavesAGap() {
        // Held: what was read last time, newest first.
        let shown = [post("p10", 10), post("p9", 9)]
        // Fresh: three newer posts, and the server says there are more behind
        // them — p11…p19 sit in neither list.
        let page = [post("p22", 22), post("p21", 21), post("p20", 20)]
        XCTAssertTrue(ChannelWords.newestLeavesGap(page, pageHasMore: true, over: shown))
    }

    func testAnOverlappingPageLeavesNoGap() {
        let shown = [post("p10", 10), post("p9", 9)]
        let page = [post("p12", 12), post("p11", 11), post("p10", 10)]
        XCTAssertFalse(ChannelWords.newestLeavesGap(page, pageHasMore: true, over: shown))
    }

    func testAPageWithNothingBehindItLeavesNoGap() {
        // The whole remainder fits in the page, so nothing is missing.
        let shown = [post("p10", 10)]
        let page = [post("p12", 12), post("p11", 11)]
        XCTAssertFalse(ChannelWords.newestLeavesGap(page, pageHasMore: false, over: shown))
    }

    func testNothingHeldIsNeverAGap() {
        XCTAssertFalse(ChannelWords.newestLeavesGap([post("p1", 1)], pageHasMore: true, over: []))
    }

    // MARK: - A thread's first page over held replies (oldest first)

    func testRefreshingTheHeadKeepsTheRepliesPagedTo() {
        // The reader paged past the first page to r4, r5.
        let held = [post("r1", 1), post("r2", 2), post("r3", 3), post("r4", 4), post("r5", 5)]
        // A live frame reloads the first page; r2 was edited in the meantime.
        var edited = post("r2", 2)
        edited = ChannelPost(id: edited.id, authorUserId: "u", body: "Поправено", kind: "POST",
                             createdAt: edited.createdAt, deleted: false, resolvedAt: nil,
                             replyCount: 0, author: nil)
        let page = [post("r1", 1), edited, post("r3", 3)]

        let merged = ChannelWords.repliesRefreshed(page, over: held)
        XCTAssertEqual(merged.map(\.id), ["r1", "r2", "r3", "r4", "r5"])
        XCTAssertEqual(merged[1].body, "Поправено", "the head shows the fresh copy")
    }

    func testRefreshingWithNothingHeldIsThePage() {
        let page = [post("r1", 1), post("r2", 2)]
        XCTAssertEqual(ChannelWords.repliesRefreshed(page, over: []).map(\.id), ["r1", "r2"])
    }

    // MARK: - Wiring

    func testTheViewsUseThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let feed = try String(contentsOf: root.appendingPathComponent("Agrent/Channels/ChannelsView.swift"), encoding: .utf8)
        let thread = try String(contentsOf: root.appendingPathComponent("Agrent/Channels/ChannelThreadView.swift"), encoding: .utf8)
        XCTAssertTrue(feed.contains("ChannelWords.newestLeavesGap("))
        XCTAssertTrue(feed.contains("if !pagedOnce { hasMore = page.hasMore }"))
        XCTAssertFalse(feed.contains("if !loaded { hasMore"), "hasMore must follow the first SUCCESSFUL page")
        XCTAssertTrue(thread.contains("ChannelWords.repliesRefreshed(page.posts, over: replies)"))
        XCTAssertFalse(thread.contains("replies = page.posts"), "a reload must not discard paged replies")
    }
}
