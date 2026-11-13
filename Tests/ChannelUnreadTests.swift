import XCTest
@testable import Agrent

/// Channel unread badges (#597) against agri-saas #2990's shape. Nothing here
/// marks a channel read.
@MainActor
final class ChannelUnreadTests: XCTestCase {

    private struct Probe: Decodable { let channels: [Channel] }

    private func channel(_ id: String, joined: Bool, unread: Int?) -> Channel {
        Channel(id: id, key: id, nameBg: id, memberCount: 3, slowModeSeconds: nil, joined: joined, banned: false,
                unreadCount: unread)
    }

    func testThePath() {
        XCTAssertEqual(ChannelsAPI.readPath("c1"), "/api/social/channels/c1/read")
    }

    func testANullCountIsNoBadgeNotZero() async throws {
        let data = Data("""
        {"channels":[
          {"id":"c1","key":"wheat","nameBg":"Пшеница","joined":true,"banned":false,"unreadCount":4},
          {"id":"c2","key":"maize","nameBg":"Царевица","joined":false,"banned":false,"unreadCount":null},
          {"id":"c3","key":"sun","nameBg":"Слънчоглед","joined":true,"banned":false}
        ]}
        """.utf8)
        let list = try await APIClient.shared.decode(data, as: Probe.self).channels
        XCTAssertEqual(list.map(\.unreadCount), [4, nil, nil], "not joined, or not sent: no count at all")
    }

    func testTheTotalCountsJoinedChannelsAndDropsOnRead() {
        let store = ChannelUnreadStore()
        store.apply([channel("c1", joined: true, unread: 4), channel("c2", joined: true, unread: 2),
                     channel("c3", joined: false, unread: nil)], asOf: SessionEpoch.current)
        XCTAssertEqual(store.total, 6)
        XCTAssertNil(store.count(for: channel("c3", joined: false, unread: nil)))

        store.markedRead("c1")
        XCTAssertEqual(store.total, 2)
        XCTAssertEqual(store.count(for: channel("c1", joined: true, unread: 4)), 0,
                       "the store's word wins over the list the row was drawn from")
        store.markedRead("c3")
        XCTAssertNil(store.counts["c3"], "reading a channel with no count invents none")

        store.reset()
        XCTAssertEqual(store.total, 0)
    }

    func testAListFromAnEndedSessionIsDropped() {
        let store = ChannelUnreadStore()
        store.apply([channel("c1", joined: true, unread: 4)], asOf: SessionEpoch.current - 1)
        XCTAssertEqual(store.total, 0)
    }

    func testTheMenuRowCarriesTheTotal() {
        XCTAssertEqual(MessagingPolicy.counted("Канали", unread: 3), "Канали (3)")
        XCTAssertEqual(MessagingPolicy.counted("Канали", unread: 0), "Канали")
    }
}
