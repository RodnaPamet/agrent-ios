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
}
