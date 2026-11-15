import XCTest
@testable import Agrent

/// «Канали»'s search (#614) against agri-saas #3072. Read-only; every fetch
/// is a closure that records what it was asked.
@MainActor
final class ChannelSearchTests: XCTestCase {

    private func post(_ id: String, _ at: Date) -> ChannelPost {
        ChannelPost(id: id, authorUserId: "u", body: "Пшеница \(id)", kind: "POST", createdAt: at,
                    deleted: false, resolvedAt: nil, replyCount: 0)
    }

    private func hit(_ id: String) -> ChannelsAPI.SearchHit {
        ChannelsAPI.SearchHit(post: post(id, Date(timeIntervalSince1970: 1_763_190_000)),
                              channelId: "c1", channelNameBg: "Пшеница")
    }

    @MainActor
    private final class Calls {
        var asked: [(String, ChannelsAPI.SearchScope, Date?, String?)] = []
        var pages: [ChannelsAPI.SearchPage] = []
        var refusal: Error?
    }

    private func search(_ calls: Calls) -> ChannelSearch {
        ChannelSearch { needle, scope, before, id in
            calls.asked.append((needle, scope, before, id))
            if let refusal = calls.refusal { throw refusal }
            return calls.pages.isEmpty ? ChannelsAPI.SearchPage(hits: [], hasMore: false, scope: scope) : calls.pages.removeFirst()
        }
    }

    func testThePath() {
        XCTAssertEqual(ChannelsAPI.searchPath("сеитба днес", scope: .all),
                       "/api/social/channel-search?q=%D1%81%D0%B5%D0%B8%D1%82%D0%B1%D0%B0%20%D0%B4%D0%BD%D0%B5%D1%81&scope=all&limit=50")
        let next = ChannelsAPI.searchPath("x", scope: .joined, before: Date(timeIntervalSince1970: 0), beforeID: "p1")
        XCTAssertTrue(next.contains("scope=joined"), next)
        XCTAssertTrue(next.hasSuffix("&beforeId=p1"), next)
    }

    /// The scope on screen is the one the server says it applied.
    func testThePageReadsAndEchoesItsScope() async throws {
        let data = Data("""
        {"hits":[{"post":{"id":"p1","authorUserId":"u","body":"Пшеница","kind":"POST","createdAt":"2026-11-15T09:00:00.000Z",
                          "deleted":false,"resolvedAt":null,"replyCount":0},
                  "channelId":"c1","channelNameBg":"Пшеница","channelNameEn":"Wheat"}],
         "hasMore":false,"scope":"all"}
        """.utf8)
        let page = try await APIClient.shared.decode(data, as: ChannelsAPI.SearchPage.self)
        XCTAssertEqual(page.scope, .all)
        XCTAssertEqual(page.hits.map(\.id), ["p1"])
        XCTAssertEqual(page.hits[0].channelNameBg, "Пшеница")
    }

    func testOneLetterAsksNothing() async {
        let calls = Calls(), search = search(calls)
        search.needle = " п "
        await search.submit()
        XCTAssertTrue(search.isActive)
        XCTAssertTrue(search.tooShort)
        XCTAssertTrue(calls.asked.isEmpty, "the server answers 400 SEARCH_TOO_SHORT to that")
    }

    /// Typing alone asks nothing: the search runs on Return, as Борса's.
    func testTypingAsksNothingUntilSubmitted() async {
        let calls = Calls(), search = search(calls)
        search.needle = "пшеница"
        XCTAssertFalse(search.isActive)
        XCTAssertTrue(calls.asked.isEmpty)
        await search.submit()
        XCTAssertEqual(calls.asked.map(\.0), ["пшеница"])
        XCTAssertEqual(calls.asked.map(\.1), [.joined], "my channels first")
        XCTAssertEqual(search.applied, .joined)

        search.needle = ""
        await search.submit()
        XCTAssertFalse(search.isActive, "a cleared field shows the channels again")
        XCTAssertEqual(calls.asked.count, 1)
    }

    /// A new scope searches the submitted words again; the same scope does not.
    func testTheScopeSearchesAgain() async {
        let calls = Calls(), search = search(calls)
        search.needle = "пшеница"
        await search.submit()
        await search.choose(.joined)
        XCTAssertEqual(calls.asked.count, 1)
        await search.choose(.all)
        XCTAssertEqual(calls.asked.map(\.1), [.joined, .all])
        XCTAssertEqual(search.applied, .all, "the server's echo")
    }

    /// An answer to words no longer asked is dropped: the second search
    /// starts while the first is still out, and only its hits show.
    func testAStaleAnswerIsDropped() async {
        var search: ChannelSearch!
        var calls = 0
        search = ChannelSearch { needle, scope, _, _ in
            calls += 1
            if calls == 1 {
                search.needle = "царевица"
                await search.submit()
                return ChannelsAPI.SearchPage(hits: [self.hit("old")], hasMore: false, scope: scope)
            }
            return ChannelsAPI.SearchPage(hits: [self.hit("new")], hasMore: false, scope: scope)
        }
        search.needle = "пшеница"
        await search.submit()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(search.submitted, "царевица")
        XCTAssertEqual(search.hits.map(\.id), ["new"], "the first words' hits must not show under the second")
        XCTAssertFalse(search.searching)
    }

    func testMorePagesOnTheOldestHitsInstantAndId() async {
        let calls = Calls(), search = search(calls)
        calls.pages = [ChannelsAPI.SearchPage(hits: [hit("p2"), hit("p1")], hasMore: true, scope: .all),
                       ChannelsAPI.SearchPage(hits: [hit("p1"), hit("p0")], hasMore: false, scope: .all)]
        search.needle = "пшеница"
        await search.choose(.all)
        await search.submit()
        await search.loadMore()
        XCTAssertEqual(search.hits.map(\.id), ["p2", "p1", "p0"], "each hit once")
        XCTAssertEqual(calls.asked.last?.3, "p1")
        XCTAssertNotNil(calls.asked.last?.2)
        XCTAssertFalse(search.hasMore)
    }

    func testARefusalIsSaidInBulgarian() async throws {
        let calls = Calls(), search = search(calls)
        calls.refusal = APIClient.APIError.http(status: 400, code: "INVALID_SCOPE", message: "bad scope")
        search.needle = "пшеница"
        await search.submit()
        let failure = try XCTUnwrap(search.failure)
        XCTAssertNotNil(failure.range(of: "\\p{Cyrillic}", options: .regularExpression), failure)
    }

    func testTheWordsNeverPromiseABestMatch() {
        for scope in [ChannelsAPI.SearchScope.joined, .all] {
            let header = ChannelWords.searchHeader(scope)
            XCTAssertTrue(header.contains("най-новите първо"), header)
            XCTAssertFalse(header.lowercased().contains("най-подходящ"), header)
        }
        for text in [ChannelWords.searchPrompt, ChannelWords.searchTooShort, ChannelWords.searchNothing,
                     ChannelWords.searchHeader(.joined), ChannelWords.searchHeader(.all)] {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }
}
