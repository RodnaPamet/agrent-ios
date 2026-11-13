import XCTest
@testable import Agrent

/// Personal messages (#593) against agri-saas P8.2's contract. Fixtures are
/// invented; nothing here sends, opens, answers or marks read.
final class DirectMessagesTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func testThePaths() {
        XCTAssertEqual(DirectMessagesAPI.inboxPath, "/api/social/inbox?source=dm",
                       "only the personal rows; an unknown source is a 400, never a fallback")
        XCTAssertEqual(DirectMessagesAPI.conversationPath("c1"), "/api/social/conversations/c1")
        XCTAssertEqual(DirectMessagesAPI.conversationPath("c1", before: "a+b="),
                       "/api/social/conversations/c1?before=a%2Bb%3D", "the cursor is escaped")
        XCTAssertEqual(DirectMessagesAPI.messagesPath("c1"), "/api/social/conversations/c1/messages")
        XCTAssertEqual(DirectMessagesAPI.readPath("c1"), "/api/social/conversations/c1/read")
        XCTAssertEqual(DirectMessagesAPI.respondPath("c1"), "/api/social/conversations/c1/respond")
        XCTAssertEqual(DirectMessagesAPI.conversationPath("a/b"), "/api/social/conversations/a%2Fb")
    }

    func testTheInboxKeepsPersonalRowsAndDropsWhatItCannotRead() async throws {
        let rows = try await DirectMessagesAPI.decodeInbox(fixture("dm-inbox"))
        XCTAssertEqual(rows.map(\.id), ["dmc_synthetic_1", "dmc_synthetic_2"])
        XCTAssertEqual(rows[0].awaitingMyAnswer, true)
        XCTAssertTrue(rows[0].unread)
        XCTAssertEqual(rows[0].name, "Синтетична ферма")
        XCTAssertNil(rows[1].awaitingMyAnswer)
        XCTAssertEqual(rows[1].name, "Лично съобщение", "no title: a name that says what it is")

        // An exchange row, or one missing its id, costs that row only.
        let mixed = Data("""
        {"items":[
          {"source":"exchange","id":"thr_1","lastMessageAt":"2026-11-13T09:00:00.000Z","lastReadAt":null,"unread":true,"awaitingMyAnswer":null,"title":null},
          {"source":"dm","lastMessageAt":"2026-11-13T09:00:00.000Z","unread":true},
          {"source":"dm","id":"dmc_ok","lastMessageAt":"2026-11-13T09:00:00.000Z","lastReadAt":null,"unread":false,"awaitingMyAnswer":false,"title":"Ферма"}
        ],"nextCursor":null,"hasMore":false}
        """.utf8)
        let kept = try await DirectMessagesAPI.decodeInbox(mixed)
        XCTAssertEqual(kept.map(\.id), ["dmc_ok"])
    }

    func testMineIsWorkedOutFromThePersonsID() async throws {
        let mine = try await DirectMessagesAPI.decodeConversation(fixture("dm-conversation"), me: "usr_fixture_other")
        XCTAssertEqual(mine.messages.map(\.mine), [true])
        XCTAssertTrue(mine.openedByMe)

        let theirs = try await DirectMessagesAPI.decodeConversation(fixture("dm-conversation"), me: "usr_fixture_owner")
        XCTAssertEqual(theirs.messages.map(\.mine), [false])
        XCTAssertFalse(theirs.openedByMe)
        XCTAssertEqual(theirs.messages.first?.speaker, .counterparty, "two people: never a colleague")

        let unknown = try await DirectMessagesAPI.decodeConversation(fixture("dm-conversation"), me: nil)
        XCTAssertEqual(unknown.messages.map(\.mine), [false], "unknown person: nothing is claimed as mine")
        XCTAssertFalse(unknown.openedByMe)
    }

    func testARequestIsAnsweredByTheOtherSideAndHoldsOneMessage() async throws {
        let received = try await DirectMessagesAPI.decodeConversation(fixture("dm-conversation"), me: "usr_fixture_owner")
        XCTAssertEqual(received.state, .request)
        XCTAssertTrue(received.awaitingMyAnswer)
        XCTAssertFalse(received.waitingForAnswer)

        let sent = try await DirectMessagesAPI.decodeConversation(fixture("dm-conversation"), me: "usr_fixture_other")
        XCTAssertFalse(sent.awaitingMyAnswer, "waiting is not owing")
        XCTAssertTrue(sent.waitingForAnswer, "my request already holds its one message")
    }

    func testARemovedMessageIsATombstone() async throws {
        let data = Data("""
        {"id":"c","state":"ACCEPTED","initiatedByUserId":"u1","lastMessageAt":null,"olderCursor":null,"hasOlder":false,"lastReadAt":null,
         "messages":[{"id":"m1","senderUserId":"u1","body":"скрито","createdAt":"2026-11-13T09:00:00.000Z","editedAt":null,"deletedAt":"2026-11-13T09:01:00.000Z","reactions":[],"attachment":null,"linkCard":null,"replyTo":null}]}
        """.utf8)
        let page = try await DirectMessagesAPI.decodeConversation(data, me: "u2")
        XCTAssertEqual(page.messages.first?.isTombstone, true)
        XCTAssertNil(page.messages.first?.body, "a removed message's text is never shown")
    }

    func testTheInboxMergesBothKindsNewestFirst() throws {
        let earlier = try XCTUnwrap(BgDate.parseInstant("2026-11-12T10:00:00.000Z"))
        let later = try XCTUnwrap(BgDate.parseInstant("2026-11-13T10:00:00.000Z"))
        let direct = [DirectInboxItem(id: "d1", lastMessageAt: later, unread: false, awaitingMyAnswer: nil, title: nil),
                      DirectInboxItem(id: "d2", lastMessageAt: earlier, unread: false, awaitingMyAnswer: nil, title: nil)]
        XCTAssertEqual(InboxEntry.merged([], direct).map(\.id), ["dm:d1", "dm:d2"])
        XCTAssertEqual(InboxEntry.merged([], []).count, 0)
    }

    func testTheSendBodyCarriesItsKey() throws {
        let body = SendDirectMessage(body: "Здравейте", idempotencyKey: "k1")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(body), encoding: .utf8))
        XCTAssertTrue(json.contains("\"idempotencyKey\":\"k1\""), "a repeat with this key returns the first message")
    }
}
