import XCTest
@testable import Agrent

/// Exchange messaging's data layer (agrent-ios#114): the nine paths, the
/// models against the synthetic fixtures, and the rules in
/// `ExchangeMessaging.swift`.
///
/// Every expectation here is a LITERAL taken from the contract — agri-saas
/// `openapi.json` and `exchange-messaging.ts` at 11b00118 — never derived from
/// the code under test. Nothing here sends a request: every messaging write is
/// built and unfired, and this suite could not observe one anyway.
final class ExchangeMessagingPathTests: XCTestCase {

    private let base = "/api/t/\(Config.tenantSlug)/exchange"

    /// All nine operations, spelled as the spec spells them.
    func testEveryOperationHasTheSpecsPath() {
        XCTAssertEqual(ExchangeAPI.threadsPath, "\(base)/threads")
        XCTAssertEqual(ExchangeAPI.threadPath("t1"), "\(base)/threads/t1")
        XCTAssertEqual(ExchangeAPI.openThreadPath(listingID: "l1"), "\(base)/listings/l1/thread")
        XCTAssertEqual(ExchangeAPI.messagesPath(threadID: "t1"), "\(base)/threads/t1/messages")
        XCTAssertEqual(ExchangeAPI.readPath(threadID: "t1"), "\(base)/threads/t1/read")
        XCTAssertEqual(ExchangeAPI.closePath(threadID: "t1"), "\(base)/threads/t1/close")
        XCTAssertEqual(ExchangeAPI.blockPath(threadID: "t1"), "\(base)/threads/t1/block")
        XCTAssertEqual(ExchangeAPI.messagePath(messageID: "m1"), "\(base)/messages/m1")
    }

    /// The first page carries no query: the fixture seam and anything keyed
    /// on the path see one stable string.
    func testTheFirstPagesCarryNoQuery() {
        XCTAssertFalse(ExchangeAPI.threadsPath.contains("?"))
        XCTAssertEqual(ExchangeAPI.threadsPath(cursor: nil), "\(base)/threads")
        XCTAssertEqual(ExchangeAPI.threadsPath(cursor: "   "), "\(base)/threads",
                       "a blank cursor is no cursor")
        XCTAssertEqual(ExchangeAPI.threadPath("t1", before: nil), "\(base)/threads/t1")
        XCTAssertEqual(ExchangeAPI.threadPath("t1", before: ""), "\(base)/threads/t1")
    }

    /// Cursors are opaque base64url today, which needs no escaping — but
    /// `APIClient.url(for:)` takes the query VERBATIM, so a `+`, `/`, `=` or
    /// `&` in one must not reach it raw. Escaped the way the board's are.
    func testCursorsAreEscaped() {
        XCTAssertEqual(ExchangeAPI.threadsPath(cursor: "MjAyNi0wOS0yOA"),
                       "\(base)/threads?cursor=MjAyNi0wOS0yOA")
        XCTAssertEqual(ExchangeAPI.threadsPath(cursor: "a+b/c=&d"),
                       "\(base)/threads?cursor=a%2Bb%2Fc%3D%26d")
        XCTAssertEqual(ExchangeAPI.threadPath("t1", before: "x=y&limit=1"),
                       "\(base)/threads/t1?before=x%3Dy%26limit%3D1")
    }

    /// Whole numbers 1…100. The server clamps too, but a non-integer reaches
    /// Prisma's `take` and probably answers 500 — so the client never sends
    /// one, and never sends a value outside the range either.
    func testTheLimitIsClampedToOneThroughAHundred() {
        for (given, sent) in [(0, 1), (-5, 1), (1, 1), (50, 50), (100, 100), (101, 100), (Int.max, 100)] {
            XCTAssertEqual(ExchangeAPI.threadsPath(cursor: nil, limit: given),
                           "\(base)/threads?limit=\(sent)", "limit \(given)")
            XCTAssertEqual(ExchangeAPI.threadPath("t1", before: nil, limit: given),
                           "\(base)/threads/t1?limit=\(sent)", "limit \(given)")
        }
        XCTAssertEqual(ExchangeAPI.threadsPath(cursor: "c", limit: 20),
                       "\(base)/threads?limit=20&cursor=c")
        XCTAssertEqual(ExchangeAPI.threadPath("t1", before: "b", limit: 20),
                       "\(base)/threads/t1?limit=20&before=b")
    }

    /// An id is one path segment. A cuid passes through unchanged; a `/` or
    /// `?` could otherwise move the request to another route or start a query.
    func testIdsCannotLeaveTheirSegment() {
        XCTAssertEqual(ExchangeAPI.threadPath("cmg1abc2d0000xyz"), "\(base)/threads/cmg1abc2d0000xyz")
        XCTAssertEqual(ExchangeAPI.threadPath("a/b?c"), "\(base)/threads/a%2Fb%3Fc")
        XCTAssertEqual(ExchangeAPI.messagePath(messageID: "../x"), "\(base)/messages/..%2Fx")
    }

    /// The send body is `{body}` and nothing else.
    func testTheSendBodyIsTheSpecsShape() async throws {
        let data = try await APIClient.shared.encodeBody(SendExchangeMessage(body: "Здравейте"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["body": "Здравейте"])
    }

    /// The messaging writes are named in the send function's signature with a
    /// `MessageSendKey`, never a `String`. Read from source because the
    /// property that matters — no call can fall through to `post`'s default
    /// fresh key — has no runtime hook in this suite.
    func testTheSendPassesItsKeyExplicitly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/API/ExchangeAPI.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("idempotencyKey: MessageSendKey"),
                      "the send must take a minted key, not a String")
        XCTAssertTrue(source.contains("idempotencyKey: idempotencyKey.value"),
                      "the send must hand its key to `post` rather than take the default")
        XCTAssertTrue(source.contains("static func createListing"),
                      "positive control: this is the file the exchange writes live in")
    }
}

// MARK: - Models, against the synthetic fixtures

final class ExchangeMessagingModelTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name).json is not in the test bundle"])
        }
        return try Data(contentsOf: url)
    }

    func testTheInboxDecodesEveryHardCase() async throws {
        let page = try await ExchangeAPI.decodeThreads(from: try fixture("exchange-threads"))
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.threads.map(\.id),
                       ["thr_synthetic_1", "thr_synthetic_4", "thr_synthetic_2", "thr_synthetic_3"])

        let first = page.threads[0]
        XCTAssertEqual(first.commodity, "wheat", "listingCommodity decodes into `commodity`")
        XCTAssertEqual(first.role, .seller)
        XCTAssertEqual(first.sellerDisplayName, "Синтетично стопанство")
        XCTAssertTrue(first.hasUnread)
        XCTAssertFalse(first.closed)
        XCTAssertEqual(first.quantity, Decimal(string: "250"))

        // #1323: a second person's thread on the SAME listing is its own row.
        let sameListing = page.threads[1]
        XCTAssertEqual(sameListing.listingId, first.listingId)
        XCTAssertNotEqual(sameListing.id, first.id)
        XCTAssertFalse(sameListing.hasUnread)

        let second = page.threads[2]
        XCTAssertNil(second.sellerDisplayName, "present-and-null is a value, not a failure")
        XCTAssertEqual(second.role, .inquirer)
        XCTAssertTrue(second.closed)
        XCTAssertEqual(second.listingQuantityTonnes, "12.5")
        XCTAssertEqual(second.quantity, Decimal(string: "12.5"))

        XCTAssertEqual(page.threads[3].role, .unknown,
                       "a role this build does not know degrades; it does not fail the inbox")
    }

    func testTheConversationDecodesItsTombstoneInPlace() async throws {
        let thread = try await ExchangeAPI.decodeThread(from: try fixture("exchange-thread"))
        XCTAssertEqual(thread.commodity, "wheat")
        XCTAssertTrue(thread.blocked)
        XCTAssertFalse(thread.closed)
        XCTAssertNil(thread.olderCursor)
        XCTAssertEqual(thread.unreadCount, 2)
        XCTAssertEqual(thread.messages.map(\.id),
                       ["msg_synthetic_1", "msg_synthetic_2", "msg_synthetic_5",
                        "msg_synthetic_3", "msg_synthetic_4"])

        let tombstone = thread.messages[3]
        XCTAssertTrue(tombstone.deleted)
        XCTAssertNil(tombstone.body)
        XCTAssertTrue(tombstone.isTombstone)
        XCTAssertFalse(tombstone.mayRetract)

        let mine = thread.messages[1]
        XCTAssertTrue(mine.mine)
        XCTAssertTrue(mine.mayRetract)
        XCTAssertEqual(mine.body, "Да, 250 т.\nМоже оглед в четвъртък.", "newlines survive")

        XCTAssertFalse(thread.messages[0].mayRetract, "never on the other farm's message")
    }

    /// agri-saas #1323: the fixture holds all three speakers, and the two new
    /// fields decode from it.
    func testTheConversationHasAllThreeSpeakers() async throws {
        let thread = try await ExchangeAPI.decodeThread(from: try fixture("exchange-thread"))
        let byID = Dictionary(uniqueKeysWithValues: thread.messages.map { ($0.id, $0) })

        let me = try XCTUnwrap(byID["msg_synthetic_2"])
        XCTAssertEqual(me.speaker, .me)
        XCTAssertEqual(me.senderUserId, "usr_synthetic_creator")

        let colleague = try XCTUnwrap(byID["msg_synthetic_5"])
        XCTAssertTrue(colleague.fromMyFarm)
        XCTAssertFalse(colleague.mine)
        XCTAssertEqual(colleague.speaker, .colleague)
        XCTAssertEqual(colleague.senderUserId, "usr_synthetic_admin")
        XCTAssertFalse(colleague.mayRetract, "a colleague's words are not mine to retract")

        let other = try XCTUnwrap(byID["msg_synthetic_1"])
        XCTAssertEqual(other.speaker, .counterparty)
        XCTAssertEqual(Set(thread.messages.map(\.speaker)), Set(MessageSpeaker.allCases))

        // agri-saas #1399: a name, and a null — the colleague has none set,
        // which is the fallback's case.
        XCTAssertEqual(other.displayName, "Петър Примеров")
        XCTAssertNil(colleague.senderName)
        XCTAssertEqual(colleague.speaker.caption(name: colleague.displayName), "Колега от стопанството")
    }

    /// A server from before #1323 sends neither field. The message still
    /// decodes, and reads as that server meant it: no colleague (a colleague's
    /// message arrived as `mine` there).
    func testAMessageFromBeforeTheChangeStillDecodes() async throws {
        let json = #"{"id":"m","senderTenantId":"x","mine":false,"body":"Да","deleted":false,"createdAt":"2026-09-28T09:15:00Z"}"#
        let message = try await APIClient.shared.decode(Data(json.utf8), as: ExchangeMessage.self)
        XCTAssertNil(message.senderUserId)
        XCTAssertNil(message.senderName, "a server from before #1399 reads as no name set")
        XCTAssertFalse(message.fromMyFarm)
        XCTAssertEqual(message.speaker, .counterparty)
    }

    /// A blank name is no name — the spec asks for a fallback, not an empty
    /// label — and a name this build cannot read costs the name, never the
    /// message.
    func testABlankOrUnreadableNameIsNoName() async throws {
        func message(name: String) async throws -> ExchangeMessage {
            let json = #"{"id":"m","senderTenantId":"x","senderUserId":"u","senderName":"#
                + name + #","mine":false,"fromMyFarm":false,"body":"Да","deleted":false,"createdAt":"2026-09-28T09:15:00Z"}"#
            return try await APIClient.shared.decode(Data(json.utf8), as: ExchangeMessage.self)
        }
        let blank = try await message(name: #""  ""#)
        XCTAssertNil(blank.displayName)
        XCTAssertEqual(blank.speaker.caption(name: blank.displayName), "Отсрещната страна")

        let odd = try await message(name: "42")
        XCTAssertNil(odd.senderName)
        XCTAssertEqual(odd.body, "Да", "the message was lost over its sender's name")

        let named = try await message(name: #"" Петър Примеров ""#)
        XCTAssertEqual(named.displayName, "Петър Примеров", "positive control: a real name, trimmed")

        // A ciphertext is never a name: `User.name` is encrypted at rest.
        let sealed = try await message(name: #""v1:FTDt/c3ludGhldGljLWNpcGhlcnRleHQ=""#)
        XCTAssertNil(sealed.displayName)
    }

    /// The other side cannot caption their words as mine or a colleague's
    /// by choosing one of the app's own speaker words as a name.
    func testAnAppSpeakerWordIsNoName() async throws {
        for forged in ["Вие", "колега от стопанството", " Отсрещната страна "] {
            let json = #"{"id":"m","senderTenantId":"x","senderUserId":"u","senderName":"\#(forged)","mine":false,"fromMyFarm":false,"body":"Да","deleted":false,"createdAt":"2026-09-28T09:15:00Z"}"#
            let message = try await APIClient.shared.decode(Data(json.utf8), as: ExchangeMessage.self)
            XCTAssertNil(message.displayName, forged)
            XCTAssertEqual(message.speaker.caption(name: message.displayName), "Отсрещната страна", forged)
        }
    }

    /// The two fields, present: decoded as sent.
    func testTheNewFieldsDecode() async throws {
        let json = #"{"id":"m","senderTenantId":"x","senderUserId":"u9","mine":false,"fromMyFarm":true,"body":"Да","deleted":false,"createdAt":"2026-09-28T09:15:00Z"}"#
        let message = try await APIClient.shared.decode(Data(json.utf8), as: ExchangeMessage.self)
        XCTAssertEqual(message.senderUserId, "u9")
        XCTAssertTrue(message.fromMyFarm)
        XCTAssertEqual(message.speaker, .colleague)
    }

    /// A retract keeps who said it: a tombstone of a colleague's message is
    /// still the colleague's.
    func testATombstoneKeepsItsSpeaker() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var conversation = Conversation(ExchangeThread(
            id: "t1", listingId: "l1", commodity: "wheat", role: .seller,
            lastMessageAt: t0, closed: false, blocked: false, unreadCount: nil, olderCursor: nil,
            messages: [ExchangeMessage(id: "a", senderTenantId: nil, senderUserId: "u2", mine: false,
                                       fromMyFarm: true, body: "х", deleted: false, createdAt: t0)]))
        conversation.tombstone("a")
        XCTAssertEqual(conversation.messages[0].speaker, .colleague)
        XCTAssertEqual(conversation.messages[0].senderUserId, "u2")
    }

    /// A body null on a message NOT marked deleted is a contract break; it
    /// shows as removed rather than as an empty bubble, and cannot be retracted.
    func testANullBodyIsATombstoneWhateverDeletedSays() async throws {
        let json = #"{"id":"m","senderTenantId":"x","mine":true,"body":null,"deleted":false,"createdAt":"2026-09-28T09:15:00Z"}"#
        let message = try await APIClient.shared.decode(Data(json.utf8), as: ExchangeMessage.self)
        XCTAssertTrue(message.isTombstone)
        XCTAssertFalse(message.mayRetract)
    }

    /// Role matching is case-insensitive, like every lenient wire enum.
    func testRolesAreLenient() async throws {
        for (raw, role) in [("seller", ExchangeThreadRole.seller), ("INQUIRER", .inquirer),
                            ("broker", .unknown), ("", .unknown)] {
            let decoded = try await APIClient.shared.decode(Data("[\"\(raw)\"]".utf8),
                                                             as: [ExchangeThreadRole].self)
            XCTAssertEqual(decoded, [role], raw)
        }
    }

    /// Side-neutral: the payloads carry no listing side, and on a BUY listing
    /// the `seller` role is the one buying. And farm-level since #1323: the
    /// role is my FARM's side, and «Вие» / «Ваш» is the person now — an admin
    /// on a colleague's listing does not own it, and a buyer-side admin on a
    /// colleague's thread is not the one asking.
    func testRoleLabelsAreSideNeutral() {
        XCTAssertEqual(ExchangeThreadRole.seller.label, "Наша обява")
        XCTAssertEqual(ExchangeThreadRole.inquirer.label, "Наше запитване")
        for role in ExchangeThreadRole.allCases {
            XCTAssertFalse(role.label.contains("продава"), role.label)
            XCTAssertFalse(role.label.contains("Вие") || role.label.contains("Ваш"), role.label)
        }
        XCTAssertTrue(ExchangeThreadRole.seller.ownsListing)
        XCTAssertFalse(ExchangeThreadRole.inquirer.ownsListing)
        XCTAssertFalse(ExchangeThreadRole.unknown.ownsListing,
                       "an unrecognised role is not offered block")
    }

    /// The send response: a replay is a delivery, and a missing flag defaults
    /// rather than failing a message that was delivered.
    func testTheSendResponseToleratesMissingFlags() async throws {
        let full = #"{"id":"m","createdAt":"2026-09-28T09:15:00.000Z","reopened":true,"replayed":false}"#
        let sent = try await APIClient.shared.decode(Data(full.utf8), as: ExchangeMessageSent.self)
        XCTAssertEqual(sent.id, "m")
        XCTAssertTrue(sent.reopened)
        XCTAssertFalse(sent.replayed)
        XCTAssertNotNil(sent.createdAt)

        let bare = try await APIClient.shared.decode(Data(#"{"id":"m"}"#.utf8), as: ExchangeMessageSent.self)
        XCTAssertEqual(bare, ExchangeMessageSent(id: "m", createdAt: nil, reopened: false, replayed: false))
    }

    func testTheOtherWriteResponsesDecode() async throws {
        let opened = try await APIClient.shared.decode(
            Data(#"{"id":"t","created":false}"#.utf8), as: ExchangeThreadOpened.self)
        XCTAssertEqual(opened, ExchangeThreadOpened(id: "t", created: false))

        let read = try await APIClient.shared.decode(
            Data(#"{"readAt":"2026-09-28T09:15:00.000Z"}"#.utf8), as: ExchangeThreadRead.self)
        XCTAssertEqual(read.readAt.timeIntervalSince1970, 1_790_586_900, accuracy: 0.001)

        let closed = try await APIClient.shared.decode(
            Data(#"{"closedAt":"2026-09-20T00:00:00.000Z","alreadyClosed":true}"#.utf8),
            as: ExchangeThreadClosed.self)
        XCTAssertTrue(closed.alreadyClosed)

        let blocked = try await APIClient.shared.decode(
            Data(#"{"blocked":true,"alreadyBlocked":true}"#.utf8), as: ExchangePartyBlocked.self)
        XCTAssertTrue(blocked.blocked && blocked.alreadyBlocked)

        let unblocked = try await APIClient.shared.decode(
            Data(#"{"blocked":false}"#.utf8), as: ExchangePartyUnblocked.self)
        XCTAssertFalse(unblocked.blocked)

        let retracted = try await APIClient.shared.decode(
            Data(#"{"id":"m"}"#.utf8), as: ExchangeMessageRetracted.self)
        XCTAssertEqual(retracted.id, "m")
    }
}

// MARK: - The rules

final class MessageSendKeyTests: XCTestCase {

    /// A counter, so each key says which mint produced it.
    private final class Minter {
        var count = 0
        func mint() -> String { count += 1; return "key-\(count)" }
    }

    func testARetryOfTheSameTextReusesTheKey() {
        let minter = Minter()
        var keys = MessageSendKeys()
        let first = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        let retry = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        let again = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        XCTAssertEqual(first.value, "key-1")
        XCTAssertEqual(retry, first)
        XCTAssertEqual(again, first)
        XCTAssertEqual(minter.count, 1, "a retry must not mint")
        XCTAssertTrue(keys.isPending(threadID: "t1", text: "Да"))
    }

    /// Changed text is a new message: the old key would replay the ORIGINAL
    /// and report the correction as sent.
    func testChangedTextGetsANewKey() {
        let minter = Minter()
        var keys = MessageSendKeys()
        let first = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        let edited = keys.key(threadID: "t1", text: "Да, в четвъртък", mint: minter.mint)
        XCTAssertNotEqual(edited, first)
        XCTAssertFalse(keys.isPending(threadID: "t1", text: "Да"))

        // And going back to the first text is a new send too — the pending key
        // follows the latest attempt, not every text ever typed.
        let back = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        XCTAssertNotEqual(back, first)
        XCTAssertEqual(minter.count, 3)
    }

    /// The server matches a replay on (farm, key) alone, so the same text in
    /// another thread must not share a key.
    func testAnotherThreadGetsANewKey() {
        let minter = Minter()
        var keys = MessageSendKeys()
        let here = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        let there = keys.key(threadID: "t2", text: "Да", mint: minter.mint)
        XCTAssertNotEqual(here, there)
    }

    /// Any 201 clears it: the same words sent afterwards are a second message.
    func testDeliveryClearsTheKey() {
        let minter = Minter()
        var keys = MessageSendKeys()
        let first = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        keys.delivered()
        XCTAssertFalse(keys.isPending(threadID: "t1", text: "Да"))
        let next = keys.key(threadID: "t1", text: "Да", mint: minter.mint)
        XCTAssertNotEqual(next, first)
    }

    /// The real minter: UUIDs, distinct, never empty — and a mint that
    /// answered empty is replaced, because an empty key probably 409s.
    func testKeysAreNeverEmpty() {
        let a = MessageSendKey()
        let b = MessageSendKey()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(UUID(uuidString: a.value))
        XCTAssertFalse(MessageSendKey(mint: { "" }).value.isEmpty)
    }
}

final class MessageBodyTests: XCTestCase {

    func testBlankIsEmpty() {
        for draft in ["", " ", "\n\n", " \t \n "] {
            XCTAssertEqual(MessageBody.validate(draft), .empty, draft.debugDescription)
        }
    }

    /// The trimmed text is what is sent — and what the send key is keyed on.
    func testTheTrimmedTextIsSent() {
        XCTAssertEqual(MessageBody.validate("  Здравейте \n"), .sendable("Здравейте"))
        XCTAssertEqual(MessageBody.validate("ред 1\nред 2"), .sendable("ред 1\nред 2"),
                       "inner newlines are the message")
    }

    /// 4000 UTF-16 units, the usecase's `MAX_BODY_LENGTH` — not the spec's 8000.
    func testTheLimitIsFourThousandUTF16Units() {
        let atLimit = String(repeating: "а", count: 4000)
        XCTAssertEqual(MessageBody.validate(atLimit), .sendable(atLimit))
        XCTAssertEqual(MessageBody.validate(atLimit + "б"), .tooLong(length: 4001))
        XCTAssertEqual(MessageBody.validate("  " + atLimit + "  "), .sendable(atLimit),
                       "whitespace the server trims does not count")
    }

    /// «👍🏽» is one Character, two code points and FOUR UTF-16 units — and the
    /// server counts units. Counting Characters would let this through.
    func testEmojiCountAsTheServerCountsThem() {
        let thumb = "👍🏽"
        XCTAssertEqual(thumb.count, 1)
        XCTAssertEqual(MessageBody.length(of: thumb), 4)
        let thousand = String(repeating: thumb, count: 1000)
        XCTAssertEqual(MessageBody.validate(thousand), .sendable(thousand))
        XCTAssertEqual(MessageBody.validate(thousand + "a"), .tooLong(length: 4001))
    }

    func testTheCounterShowsOnlyNearTheLimit() {
        XCTAssertFalse(MessageBody.showsCounter("Здравейте"))
        XCTAssertFalse(MessageBody.showsCounter(String(repeating: "а", count: 3599)))
        XCTAssertTrue(MessageBody.showsCounter(String(repeating: "а", count: 3600)))
        XCTAssertTrue(MessageBody.showsCounter(String(repeating: "а", count: 5000)))
    }
}

final class ConversationMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ id: String, at seconds: TimeInterval, mine: Bool = false,
                         deleted: Bool = false) -> ExchangeMessage {
        ExchangeMessage(id: id, senderTenantId: nil, mine: mine,
                        body: deleted ? nil : "текст \(id)", deleted: deleted,
                        createdAt: t0.addingTimeInterval(seconds))
    }

    private func page(_ messages: [ExchangeMessage], olderCursor: String? = nil) -> ExchangeThread {
        ExchangeThread(id: "t1", listingId: "l1", commodity: "wheat", role: .seller,
                       lastMessageAt: messages.last?.createdAt ?? t0, closed: false,
                       blocked: false, unreadCount: nil, olderCursor: olderCursor,
                       messages: messages)
    }

    func testTheFirstPageSetsTheCursorAndTheEnd() {
        let short = Conversation(page([message("a", at: 0)]))
        XCTAssertTrue(short.exhausted)
        XCTAssertFalse(short.canLoadOlder)

        let long = Conversation(page([message("b", at: 1)], olderCursor: "c1"))
        XCTAssertFalse(long.exhausted)
        XCTAssertTrue(long.canLoadOlder)
        XCTAssertEqual(long.olderCursor, "c1")
    }

    /// A poll is merged by id: nothing duplicated, the new message reported.
    func testAPollAddsOnlyWhatIsNew() {
        var conversation = Conversation(page([message("a", at: 0), message("b", at: 1)]))
        let arrival = conversation.mergeNewest(page([message("a", at: 0), message("b", at: 1),
                                                     message("c", at: 2)]))
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(arrival.new.map(\.id), ["c"])
        XCTAssertFalse(arrival.discontinuous)
        XCTAssertTrue(arrival.fromSomeoneElse)
    }

    /// THE WEB'S BUG, NOT COPIED: once older pages are loaded, a poll's newest
    /// page no longer reaches them, and replacing would drop them. Merging
    /// keeps every loaded message.
    func testAPollNeverDropsScrollback() {
        var conversation = Conversation(page([message("c", at: 2), message("d", at: 3)],
                                             olderCursor: "before-c"))
        conversation.mergeOlder(page([message("a", at: 0), message("b", at: 1)]))
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b", "c", "d"])

        // A page of two: the newest now starts at `d`, one past `c`.
        conversation.mergeNewest(page([message("d", at: 3), message("e", at: 4)],
                                      olderCursor: "before-d"))
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertNil(conversation.olderCursor, "a poll never moves the scrollback cursor")
        XCTAssertTrue(conversation.exhausted)
    }

    /// A message that commits late can arrive AFTER a newer one is on screen.
    /// It goes where its time puts it, not at the end.
    func testALateCommitIsPlacedByItsTime() {
        var conversation = Conversation(page([message("a", at: 0), message("c", at: 2)]))
        let arrival = conversation.mergeNewest(page([message("a", at: 0), message("b", at: 1),
                                                     message("c", at: 2)]))
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(arrival.new.map(\.id), ["b"])
    }

    /// Equal instants fall back to the id, as the server orders them.
    func testEqualTimesAreOrderedById() {
        let conversation = Conversation(page([message("m2", at: 5), message("m1", at: 5),
                                              message("m0", at: 4)]))
        XCTAssertEqual(conversation.messages.map(\.id), ["m0", "m1", "m2"])
    }

    /// A message retracted since it was loaded comes back as a tombstone, and
    /// the tombstone replaces it: the retracted text must not stay readable.
    func testTheIncomingCopyWins() {
        var conversation = Conversation(page([message("a", at: 0), message("b", at: 1)]))
        let arrival = conversation.mergeNewest(page([message("a", at: 0),
                                                     message("b", at: 1, deleted: true)]))
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b"])
        XCTAssertTrue(conversation.messages[1].isTombstone)
        XCTAssertTrue(arrival.new.isEmpty, "a changed message is not a new one")
    }

    /// Older pages: new ids are added, and the cursor walks on.
    func testAnOlderPageWalksBack() {
        var conversation = Conversation(page([message("e", at: 4)], olderCursor: "before-e"))
        conversation.mergeOlder(page([message("c", at: 2), message("d", at: 3)],
                                     olderCursor: "before-c"))
        XCTAssertEqual(conversation.messages.map(\.id), ["c", "d", "e"])
        XCTAssertEqual(conversation.olderCursor, "before-c")
        XCTAssertFalse(conversation.exhausted)

        conversation.mergeOlder(page([message("a", at: 0), message("b", at: 1)]))
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertTrue(conversation.exhausted, "a null cursor is the start")
        XCTAssertFalse(conversation.canLoadOlder)
    }

    /// A malformed `before` is answered with the NEWEST page and a 200. Every
    /// id is known, so the walk ends instead of repeating the conversation.
    func testAnOlderPageWithNothingNewEndsTheWalk() {
        var conversation = Conversation(page([message("b", at: 1), message("c", at: 2)],
                                             olderCursor: "before-b"))
        conversation.mergeOlder(page([message("b", at: 1), message("c", at: 2)],
                                     olderCursor: "before-b"))
        XCTAssertEqual(conversation.messages.map(\.id), ["b", "c"])
        XCTAssertTrue(conversation.exhausted)
        XCTAssertFalse(conversation.canLoadOlder)

        conversation.mergeOlder(page([]))
        XCTAssertEqual(conversation.messages.map(\.id), ["b", "c"], "an empty page adds nothing")
    }

    /// More than a page arrived while polling was paused: the newest page
    /// does not overlap what was loaded. Merging would hide the hole, so the
    /// list restarts from the newest page and the hole is walkable.
    func testAGapReplacesRatherThanHides() {
        var conversation = Conversation(page([message("a", at: 0), message("b", at: 1)]))
        let arrival = conversation.mergeNewest(page([message("y", at: 50), message("z", at: 51)],
                                                    olderCursor: "before-y"))
        XCTAssertTrue(arrival.discontinuous)
        XCTAssertEqual(arrival.new.map(\.id), ["y", "z"])
        XCTAssertEqual(conversation.messages.map(\.id), ["y", "z"])
        XCTAssertEqual(conversation.olderCursor, "before-y")
        XCTAssertTrue(conversation.canLoadOlder)
    }

    /// No gap when the newest page reaches the start, or when nothing was
    /// loaded before it.
    func testNoGapWithoutOlderMessagesBehindThePage() {
        var empty = Conversation(page([]))
        let first = empty.mergeNewest(page([message("a", at: 0)], olderCursor: "before-a"))
        XCTAssertFalse(first.discontinuous)
        XCTAssertEqual(empty.messages.map(\.id), ["a"])

        var conversation = Conversation(page([message("a", at: 0)]))
        let whole = conversation.mergeNewest(page([message("b", at: 1)]))
        XCTAssertFalse(whole.discontinuous)
        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b"])
    }

    /// Anyone's arrivals but mine are what marking read is for — a
    /// colleague's included since #1323, because the pointer is the person's
    /// and `hasUnread` does not look at who wrote. A tombstone counts, because
    /// it still moved `lastMessageAt`.
    func testWhoseArrivalItIs() {
        XCTAssertFalse(Conversation.Arrival(new: [message("m", at: 0, mine: true)]).fromSomeoneElse)
        XCTAssertTrue(Conversation.Arrival(new: [message("m", at: 0, deleted: true)]).fromSomeoneElse)
        XCTAssertFalse(Conversation.Arrival(new: []).fromSomeoneElse)
        let colleague = ExchangeMessage(id: "c", senderTenantId: nil, mine: false, fromMyFarm: true,
                                        body: "х", deleted: false, createdAt: t0)
        XCTAssertTrue(Conversation.Arrival(new: [colleague]).fromSomeoneElse,
                      "a colleague's reply would otherwise leave «Ново» on my row")
    }
}

final class ReadMarkingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func arrival(mine: Bool) -> Conversation.Arrival {
        Conversation.Arrival(new: [ExchangeMessage(
            id: "m", senderTenantId: nil, mine: mine, body: "х", deleted: false, createdAt: t0)])
    }

    /// After the first load, even with nothing unread by `unreadCount` — an
    /// opened-but-empty thread is `hasUnread` on the inbox.
    func testTheFirstLoadMarks() {
        var marking = ReadMarking()
        XCTAssertTrue(marking.shouldMarkAfterFirstLoad(visible: true))
        XCTAssertFalse(marking.shouldMarkAfterFirstLoad(visible: true), "once")
    }

    /// Owner decision 2: again when a poll brings the other farm's message
    /// while on screen — and not for this farm's own.
    func testAPollFromTheOtherPartyMarksAgain() {
        var marking = ReadMarking()
        _ = marking.shouldMarkAfterFirstLoad(visible: true)
        XCTAssertFalse(marking.shouldMark(after: Conversation.Arrival(new: []), visible: true))
        XCTAssertFalse(marking.shouldMark(after: arrival(mine: true), visible: true))
        XCTAssertTrue(marking.shouldMark(after: arrival(mine: false), visible: true))
        XCTAssertTrue(marking.shouldMark(after: arrival(mine: false), visible: true))
    }

    /// Not on screen, or not active: nothing has been read, and the first
    /// mark waits for the screen.
    func testNothingIsMarkedUnseen() {
        var marking = ReadMarking()
        XCTAssertFalse(marking.shouldMarkAfterFirstLoad(visible: false))
        XCTAssertFalse(marking.markedOnce)
        XCTAssertTrue(marking.shouldMark(after: Conversation.Arrival(new: []), visible: true),
                      "the deferred first mark fires once visible")
        XCTAssertFalse(marking.shouldMark(after: arrival(mine: false), visible: false))
    }

    /// The interim rule: a pointer that landed after the newest message shown
    /// may have passed one never seen, so refetch once.
    func testRefetchWhenThePointerPassedTheNewestShown() {
        XCTAssertTrue(ReadMarking.needsRefetch(readAt: t0.addingTimeInterval(1), newestShown: t0))
        XCTAssertFalse(ReadMarking.needsRefetch(readAt: t0, newestShown: t0))
        XCTAssertFalse(ReadMarking.needsRefetch(readAt: t0, newestShown: t0.addingTimeInterval(1)))
        XCTAssertTrue(ReadMarking.needsRefetch(readAt: t0, newestShown: nil),
                      "an empty conversation may have gained its first message")
    }
}

final class ExchangeInboxTests: XCTestCase {

    /// THREADS with something unread, by `hasUnread` — the fixture has two.
    func testTheBadgeCountsThreadsWithHasUnread() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "exchange-threads",
                                                   withExtension: "json") else {
            return XCTFail("exchange-threads.json is not in the test bundle")
        }
        let page = try await ExchangeAPI.decodeThreads(from: try Data(contentsOf: url))
        XCTAssertEqual(ExchangeInbox.unreadCount(page.threads), 2)
        XCTAssertEqual(ExchangeInbox.unreadCount([]), 0)
    }
}

// MARK: - The refusals, in Bulgarian

final class ExchangeMessagingErrorTests: XCTestCase {

    private let codes = [
        "THREAD_NOT_FOUND", "THREAD_NOT_A_PARTY", "BLOCK_SELLER_ONLY", "LISTING_NOT_FOUND",
        "THREAD_OWN_LISTING", "THREAD_BLOCKED", "MESSAGE_EMPTY", "MESSAGE_TOO_LONG",
        "MESSAGE_NOT_FOUND", "MESSAGE_NOT_SENDER",
    ]

    /// Every code the messaging usecase throws has Bulgarian — otherwise the
    /// server's English sentence is what a farmer reads.
    func testEveryMessagingCodeIsSaidInBulgarian() {
        for code in codes {
            let text = UserMessage.httpText(status: 403, code: code, message: "English sentence here.")
            XCTAssertEqual(text, UserMessage.bulgarian[code], code)
            XCTAssertFalse(text.contains("English"), code)
        }
    }

    /// The send budget is the whole farm's, so nothing speaks of "this
    /// conversation" as the thing that ran out — and «продавач» is not
    /// assumed where the listing owner may be buying.
    func testTheWordingIsNeitherPerConversationNorSided() {
        for code in codes {
            let text = UserMessage.bulgarian[code] ?? ""
            XCTAssertFalse(text.lowercased().contains("в този разговор"), code)
            XCTAssertFalse(text.lowercased().contains("продавач"), code)
        }
    }

    /// A 429 on a send stays the status sentence, whatever code rides along.
    func testARateLimitedSendIsSaidByStatus() {
        XCTAssertEqual(
            UserMessage.httpText(status: 429, code: "RATE_LIMITED",
                                 message: "Too many requests. Retry after 12 seconds."),
            UserMessage.statusText(429))
    }
}
