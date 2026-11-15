import XCTest
@testable import Agrent

/// «За Вас» (P9.7, #614) against agri-saas `readMyActivity`. Read-only:
/// nothing here sends.
final class ForYouTests: XCTestCase {

    private let page = Data("""
    {"items":[
      {"post":{"id":"p2","authorUserId":"u2","body":"@Иван виж това","kind":"POST","createdAt":"2026-11-15T09:00:00.000Z",
               "deleted":false,"resolvedAt":null,"replyCount":0,"author":{"displayName":"Мария","farmName":"Ферма Изток"}},
       "channelId":"c1","channelNameBg":"Пшеница","channelNameEn":"Wheat","reason":"mention","parentPostId":null},
      {"post":{"id":"p1","authorUserId":"u3","body":"Съгласен","kind":"POST","createdAt":"2026-11-15T08:00:00.000Z",
               "deleted":false,"resolvedAt":null,"replyCount":0,"author":null},
       "channelId":"c2","channelNameBg":"Добруджа","channelNameEn":"Dobrudzha","reason":"reply","parentPostId":"p0"},
      {"post":{"id":"p9","authorUserId":"u3","body":"","kind":"POST","createdAt":"2026-11-15T07:00:00.000Z",
               "deleted":true,"resolvedAt":null,"replyCount":0,"author":null},
       "channelId":"c2","channelNameBg":"Добруджа","channelNameEn":"Dobrudzha","reason":"repost","parentPostId":null}
    ],"hasMore":true}
    """.utf8)

    func testThePath() {
        XCTAssertEqual(ChannelsAPI.activityPath(), "/api/social/activity?limit=50")
        let before = ChannelsAPI.activityPath(before: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(before.hasPrefix("/api/social/activity?limit=50&before="), before)
        XCTAssertFalse(before.contains(":"), "the instant is escaped in the query")
        XCTAssertFalse(before.contains("beforeId"), "no id without one given")
    }

    /// The tie-break: posts written by one statement share an instant, and
    /// the instant alone dropped all but one of them at a page boundary.
    func testTheCursorCarriesTheOldestRowsId() {
        let at = Date(timeIntervalSince1970: 0)
        let activity = ChannelsAPI.activityPath(before: at, beforeID: "p 9")
        XCTAssertTrue(activity.hasSuffix("&beforeId=p%209"), activity)
        let feed = ChannelsAPI.feedPath("c1", before: at, beforeID: "p9")
        XCTAssertTrue(feed.contains("&before="), feed)
        XCTAssertTrue(feed.hasSuffix("&beforeId=p9"), feed)
        XCTAssertEqual(ChannelsAPI.page(before: nil, id: "p9"), "", "an id is nothing without its instant")
    }

    func testThePageReads() async throws {
        let decoded = try await APIClient.shared.decode(page, as: ChannelsAPI.ActivityPage.self)
        XCTAssertTrue(decoded.hasMore)
        XCTAssertEqual(decoded.items.map(\.id), ["p2", "p1", "p9"])
        XCTAssertEqual(decoded.items[0].reason, .mention)
        XCTAssertNil(decoded.items[0].parentPostId)
        XCTAssertEqual(decoded.items[1].reason, .reply)
        XCTAssertEqual(decoded.items[1].parentPostId, "p0")
        XCTAssertEqual(decoded.items[2].reason, .unknown, "a new reason does not lose the page")
    }

    /// The sentence is the phone's, in the channel's Bulgarian name.
    @MainActor func testTheWords() async throws {
        let items = try await APIClient.shared.decode(page, as: ChannelsAPI.ActivityPage.self).items
        XCTAssertEqual(ChannelWords.reason(items[0]), "Спомена Ви в «Пшеница»")
        XCTAssertEqual(ChannelWords.reason(items[1]), "Отговор на Ваша публикация в «Добруджа»")
        XCTAssertEqual(ChannelWords.reason(items[2]), "В «Добруджа»")
        XCTAssertEqual(ChannelWords.forYou, "За Вас")
        for text in items.map(ChannelWords.reason) + [ChannelWords.forYouEmpty, ChannelWords.forYouHint] {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
            XCTAssertFalse(text.contains("Активност"), "owner ruling 2026-11-14")
        }
    }

    /// A page boundary can repeat a post; it shows once, newest first.
    func testPagesMergeWithoutRepeats() async throws {
        let items = try await APIClient.shared.decode(page, as: ChannelsAPI.ActivityPage.self).items
        let merged = ChannelWords.merged(Array(items[1...]), into: Array(items[..<2]))
        XCTAssertEqual(merged.map(\.id), ["p2", "p1", "p9"])
    }

    /// Ten cards from one `createMany` share an instant. The newest page
    /// holds the first two; the rest, read before as older pages, stay
    /// below, each once. The instant is the one the server writes for such
    /// a batch (one statement, one `now()`), and the test checks the tie
    /// is real before trusting the merge.
    func testTheNewestPageKeepsTiedOlderPostsOnce() throws {
        func post(_ id: String, _ at: Date) -> ChannelPost {
            ChannelPost(id: id, authorUserId: "system", body: "Карта \(id)", kind: "CARD", createdAt: at,
                        deleted: false, resolvedAt: nil, replyCount: 0, author: nil)
        }
        let batch = Date(timeIntervalSince1970: 1_763_190_000.123)
        let cards = (0..<10).map { post("c\(9 - $0)", batch) }
        XCTAssertEqual(Set(cards.map(\.createdAt)).count, 1, "positive control: the ten share one instant")
        let newer = post("n1", batch.addingTimeInterval(60))

        // On screen: everything read so far, newest first.
        let shown = [newer] + cards
        // A fresh newest page: a new post, the older one, and two cards.
        let fresh = [post("n2", batch.addingTimeInterval(120)), newer] + cards.prefix(2)
        let merged = ChannelWords.newest(fresh, over: shown)
        XCTAssertEqual(merged.map(\.id), ["n2", "n1"] + cards.map(\.id), "every card, in order")
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count, "no post twice")
    }
}
