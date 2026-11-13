import XCTest
@testable import Agrent

/// «Канали» (P9.8, #583) against agri-saas #2986. Fixtures are invented;
/// nothing here posts.
final class ChannelsTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func testThePathsAndTheirOppositeCursors() throws {
        XCTAssertEqual(ChannelsAPI.listPath, "/api/social/channels")
        XCTAssertEqual(ChannelsAPI.feedPath("c1"), "/api/social/channels/c1?limit=50")
        let at = try XCTUnwrap(BgDate.parseInstant("2026-11-12T09:00:00.000Z"))
        XCTAssertTrue(ChannelsAPI.feedPath("c1", before: at).contains("&before=2026"), "the feed pages BACK")
        XCTAssertTrue(ChannelsAPI.repliesPath("p1", after: at).contains("&after=2026"), "a thread pages ON")
        XCTAssertFalse(ChannelsAPI.feedPath("c1", before: at).contains(":"), "the cursor is escaped in the query")
        XCTAssertEqual(ChannelsAPI.joinPath("c1"), "/api/social/channels/c1/join")
        XCTAssertFalse(ChannelsAPI.listPath.hasPrefix("/api/t/"), "tenantless: every role reaches it")
    }

    func testTheDirectoryGroupsByKeyPrefix() async throws {
        struct List: Decodable { let channels: [Channel] }
        let channels = try await APIClient.shared.decode(fixture("channels-list"), as: List.self).channels
        let sections = ChannelWords.sections(channels)
        XCTAssertEqual(sections.map(\.title), ["Моите канали", "Области", "Торове, препарати и горива", "Други"])
        XCTAssertEqual(sections[0].channels.first?.unreadCount, 2)
        XCTAssertEqual(ChannelWords.group("input:diesel"), "Торове, препарати и горива", "by prefix, not kind")
        XCTAssertEqual(ChannelWords.group("event:fair"), "Други")
        XCTAssertEqual(ChannelWords.members(34), "34 членове")
    }

    func testAPostSaysWhoWithoutAnID() async throws {
        let page = try await APIClient.shared.decode(fixture("channel-feed"), as: ChannelPage.self)
        XCTAssertEqual(page.posts.count, 3)
        XCTAssertEqual(ChannelWords.author(page.posts[0]), "Синтетичен Земеделец, Синтетична ферма")
        XCTAssertNil(ChannelWords.author(page.posts[1]), "no author sent: nothing, never the id")
        XCTAssertTrue(page.posts[1].deleted)
        XCTAssertEqual(ChannelWords.author(page.posts[2], me: "usr_fixture_owner"), "Вие", "the reader's own post")
        let farmOnly = ChannelPost(id: "x", authorUserId: "u", body: "т", kind: "POST", createdAt: Date(), deleted: false,
                                   resolvedAt: nil, replyCount: 0, author: .init(displayName: nil, farmName: "ЗК Победа"))
        XCTAssertEqual(ChannelWords.author(farmOnly), "ЗК Победа", "no published profile name: the farm alone")
        let nameOnly = ChannelPost(id: "y", authorUserId: "u", body: "т", kind: "POST", createdAt: Date(), deleted: false,
                                   resolvedAt: nil, replyCount: 0, author: .init(displayName: "Иван Петров", farmName: " "))
        XCTAssertEqual(ChannelWords.author(nameOnly), "Иван Петров", "a post made as no farm: the name alone")
        XCTAssertEqual(ChannelWords.nameAndFarm("А", "Б"), "А, Б", "the web's catalogue join")
        XCTAssertEqual(ChannelWords.badge(page.posts[0]), "Въпрос")
        XCTAssertEqual(ChannelWords.badge(page.posts[2]), "Решен въпрос")
        XCTAssertEqual(ChannelWords.replies(2), "2 отговора")
        XCTAssertNil(ChannelWords.replies(0))
    }

    func testAThreadReadsItsRepliesKey() async throws {
        let page = try await APIClient.shared.decode(fixture("channel-replies"), as: ChannelPage.self)
        XCTAssertEqual(page.posts.map(\.id), ["cr_1", "cr_2"])
        XCTAssertFalse(page.hasMore)
    }

    func testTheCounterShowsNearTheLimit() {
        XCTAssertNil(ChannelWords.counter(String(repeating: "а", count: 100)))
        XCTAssertEqual(ChannelWords.counter(String(repeating: "а", count: 3700)), "3700 / 4000")
    }

    /// A reply push finds its post in the newest pages only, paging back by
    /// the oldest post read, and gives up on the channel past the bound.
    func testAPushFindsItsPostWithinABound() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        @Sendable func post(_ n: Int) -> ChannelPost {
            ChannelPost(id: "p\(n)", authorUserId: "u", body: "x", kind: "POST",
                        createdAt: start.addingTimeInterval(-Double(n) * 60), deleted: false, resolvedAt: nil, replyCount: 0)
        }
        // Ten pages of two posts, newest first.
        let page: @Sendable (Date?) async throws -> ChannelPage = { before in
            let n = before.map { Int((start.timeIntervalSince($0) / 60).rounded()) + 1 } ?? 0
            return ChannelPage(posts: [post(n), post(n + 1)], hasMore: n + 2 < 20)
        }
        let third = try await ChannelLinkView.find("p5", page: page)
        XCTAssertEqual(third?.id, "p5", "on the third page")
        let beyond = try await ChannelLinkView.find("p12", page: page)
        XCTAssertNil(beyond, "past four pages it opens the channel")
        let last = try await ChannelLinkView.find("p19", pages: 20, page: page)
        XCTAssertEqual(last?.id, "p19", "a positive control at the far end")
        let ended: @Sendable (Date?) async throws -> ChannelPage = { _ in ChannelPage(posts: [post(0)], hasMore: false) }
        let none = try await ChannelLinkView.find("p3", page: ended)
        XCTAssertNil(none, "no more pages, no post")
    }

    /// The prompt's signal (agri-saas #2989): null whenever a channel would
    /// show no name, a blank name included.
    func testTheNameSignal() async throws {
        let none = try await APIClient.shared.decode(fixture("channel-profile"), as: PersonName.self)
        XCTAssertTrue(none.needsName)
        XCTAssertFalse(none.published)
        let blank = try await APIClient.shared.decode(Data(#"{"displayName":"  ","published":true}"#.utf8), as: PersonName.self)
        XCTAssertTrue(blank.needsName, "a blank name shows nothing, so it asks")
        let set = try await APIClient.shared.decode(Data(#"{"displayName":"Иван Петров","published":true}"#.utf8),
                                                    as: PersonName.self)
        XCTAssertFalse(set.needsName, "positive control")
        XCTAssertEqual(ChannelsAPI.profilePath, "/api/social/profile")
    }

    /// The web's words, kept whole: the hint is the consent.
    func testThePromptSaysWhereTheNameIsSeen() {
        XCTAssertEqual(ChannelWords.nameTitle, "Как да Ви наричаме?")
        XCTAssertEqual(ChannelWords.nameHint,
                       "Името Ви ще се вижда от други стопанства в каналите, заедно с името на стопанството Ви.")
        XCTAssertEqual(ChannelWords.nameSkipped, "Публикациите Ви ще се подписват само с името на стопанството.")
        for text in [ChannelWords.nameTitle, ChannelWords.nameHint, ChannelWords.nameSaved, ChannelWords.nameFailed,
                     ChannelWords.nameSkipped, ChannelWords.namePlaceholder] {
            XCTAssertNil(text.range(of: "[ыэё]", options: .regularExpression), text)
        }
    }

    /// The farm a post is made as goes in the body; omitted, the post names
    /// no farm for ever.
    func testAPostCarriesItsFarm() throws {
        let body = try JSONEncoder().encode(ChannelsAPI.NewPost(body: "т", kind: "POST", tenantSlug: "ferma-1"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["tenantSlug"] as? String, "ferma-1")
        let reply = try JSONEncoder().encode(ChannelsAPI.NewReply(body: "т", alsoToChannel: false, tenantSlug: "ferma-1"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["tenantSlug"] as? String, "ferma-1")
    }
}
