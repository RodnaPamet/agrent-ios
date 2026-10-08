import XCTest
@testable import Agrent

/// Conversations private to PEOPLE, not shared by the farm — agri-saas #1323,
/// implementing the owner's rulings on #1298.
///
/// Expectations are literals taken from the spec (`ExchangeMessage`,
/// `ExchangeThread`, `ExchangeThreadSummary` at agri-saas 7af43f9) and from
/// the usecase, never read back from the code under test. Nothing here sends
/// a request.

// MARK: - Three speakers

@MainActor
final class MessageSpeakerTests: XCTestCase {

    /// Every combination of the two flags, against the spec's description:
    /// `mine` is you; `fromMyFarm` (and not mine) a colleague; both false the
    /// counterparty.
    func testTheTwoFlagsMapToThreeSpeakers() {
        XCTAssertEqual(MessageSpeaker(mine: true, fromMyFarm: false), .me)
        XCTAssertEqual(MessageSpeaker(mine: false, fromMyFarm: true), .colleague)
        XCTAssertEqual(MessageSpeaker(mine: false, fromMyFarm: false), .counterparty)
        // Not a state the server produces (`fromMyFarm` is "my farm and not
        // me"); if it ever arrived, the server's own `mine` wins.
        XCTAssertEqual(MessageSpeaker(mine: true, fromMyFarm: true), .me)
    }

    /// Three different captions, «Вие» being the person.
    func testEachSpeakerHasItsOwnCaption() {
        XCTAssertEqual(MessageSpeaker.me.label, "Вие")
        XCTAssertEqual(MessageSpeaker.colleague.label, "Колега от стопанството")
        XCTAssertEqual(MessageSpeaker.counterparty.label, "Отсрещната страна")
        XCTAssertEqual(Set(MessageSpeaker.allCases.map(\.label)).count, MessageSpeaker.allCases.count,
                       "no two speakers share a caption")
    }

    /// My farm's side is trailing — me AND a colleague; the other side leading.
    func testAColleagueSitsOnMyFarmsSide() {
        XCTAssertTrue(MessageSpeaker.me.isOurSide)
        XCTAssertTrue(MessageSpeaker.colleague.isOurSide)
        XCTAssertFalse(MessageSpeaker.counterparty.isOurSide)
    }

    /// The VoiceOver sentence opens with WHO, per speaker, so a colleague's
    /// words are never heard as the reader's own.
    func testVoiceOverSaysTheSpeakerFirst() {
        XCTAssertEqual(MessageBubble.spoken(speaker: .me, body: "Да", time: "08:30"),
                       "Вие, Да, 08:30.")
        XCTAssertEqual(MessageBubble.spoken(speaker: .colleague, body: "Може и в петък", time: "08:45"),
                       "Колега от стопанството, Може и в петък, 08:45.")
        XCTAssertEqual(MessageBubble.spoken(speaker: .counterparty, body: "Здравейте", time: "08:00"),
                       "Отсрещната страна, Здравейте, 08:00.")
    }

    /// agri-saas #1399: the sender's name when the server has one, what they
    /// are to me when it has none — and «Вие» for my own words whatever my
    /// name is.
    func testTheCaptionIsTheSendersNameWhenThereIsOne() {
        XCTAssertEqual(MessageSpeaker.me.caption(name: "Иван Фикстуров"), "Вие")
        XCTAssertEqual(MessageSpeaker.colleague.caption(name: "Мария Синтетична"), "Мария Синтетична")
        XCTAssertEqual(MessageSpeaker.counterparty.caption(name: "Петър Примеров"), "Петър Примеров")
        XCTAssertEqual(MessageSpeaker.colleague.caption(name: nil), "Колега от стопанството")
        XCTAssertEqual(MessageSpeaker.counterparty.caption(name: nil), "Отсрещната страна")
    }

    /// What the sender is to me FIRST, in the app's own words, then their
    /// name: VoiceOver hears neither the side nor the style that tell a
    /// sighted reader whose words these are, and a name is the sender's to
    /// choose. My own words are «Вие» alone.
    func testVoiceOverSaysWhoTheyAreToMeFirst() {
        XCTAssertEqual(MessageBubble.spoken(speaker: .colleague, name: "Мария Синтетична",
                                            body: "Може и в петък", time: "08:45"),
                       "Колега от стопанството, Мария Синтетична, Може и в петък, 08:45.")
        XCTAssertEqual(MessageBubble.spoken(speaker: .counterparty, name: "Петър Примеров",
                                            body: "Здравейте", time: "08:00"),
                       "Отсрещната страна, Петър Примеров, Здравейте, 08:00.")
        XCTAssertEqual(MessageBubble.spoken(speaker: .me, name: "Иван Фикстуров", body: "Да", time: "08:30"),
                       "Вие, Да, 08:30.")
        // A name with commas in it still comes AFTER the role, so it cannot
        // stand in for one.
        XCTAssertTrue(MessageBubble.spoken(speaker: .counterparty, name: "Вие, Иван",
                                           body: "Да", time: "08:30").hasPrefix("Отсрещната страна, "))
    }

    /// Only my own message offers «Премахни» — the server compares the
    /// sending PERSON since #1323.
    func testOnlyMyOwnMessageMayBeRetracted() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func message(mine: Bool, fromMyFarm: Bool) -> ExchangeMessage {
            ExchangeMessage(id: "m", senderTenantId: nil, mine: mine, fromMyFarm: fromMyFarm,
                            body: "х", deleted: false, createdAt: t0)
        }
        XCTAssertTrue(message(mine: true, fromMyFarm: false).mayRetract)
        XCTAssertFalse(message(mine: false, fromMyFarm: true).mayRetract)
        XCTAssertFalse(message(mine: false, fromMyFarm: false).mayRetract)
    }
}

// MARK: - The inbox

final class InboxSiblingTests: XCTestCase {

    private func row(_ id: String, listing: String, role: ExchangeThreadRole = .seller) -> ExchangeThreadSummary {
        ExchangeThreadSummary(id: id, listingId: listing, commodity: "wheat", listingRegionName: nil,
                              listingQuantityTonnes: nil, sellerDisplayName: nil, role: role,
                              lastMessageAt: Date(timeIntervalSince1970: 0), closed: false,
                              hasUnread: false)
    }

    /// Two people on one listing are two rows, each told it is one of two;
    /// a row alone on its listing says nothing.
    func testRowsOnOneListingAreMarkedAsSeveral() {
        let siblings = ExchangeInbox.siblings([
            row("a", listing: "L1"), row("b", listing: "L2"), row("c", listing: "L1"),
            row("d", listing: "L3", role: .inquirer), row("e", listing: "L3", role: .inquirer),
            row("f", listing: "L3", role: .inquirer),
        ])
        XCTAssertEqual(siblings, ["a": 2, "c": 2, "d": 3, "e": 3, "f": 3])
        XCTAssertNil(siblings["b"], "positive control: a single row is left alone")
    }

    func testAnInboxOfOnesHasNoSiblings() {
        XCTAssertTrue(ExchangeInbox.siblings([row("a", listing: "L1"), row("b", listing: "L2")]).isEmpty)
        XCTAssertTrue(ExchangeInbox.siblings([]).isEmpty)
    }

    /// The note is a full Bulgarian phrase with the counted form.
    func testTheNoteSaysHowMany() {
        XCTAssertEqual(ExchangeInbox.siblingNote(2), "Един от 2 разговора по тази обява")
        XCTAssertEqual(ExchangeInbox.siblingNote(5), "Един от 5 разговора по тази обява")
    }

    /// The synthetic inbox has two people on `lst_synthetic_1`.
    func testTheFixtureHoldsTwoPeopleOnOneListing() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "exchange-threads", withExtension: "json")
        else { return XCTFail("exchange-threads.json is not in the test bundle") }
        let page = try await ExchangeAPI.decodeThreads(from: try Data(contentsOf: url))
        XCTAssertEqual(ExchangeInbox.siblings(page.threads), ["thr_synthetic_1": 2, "thr_synthetic_4": 2])
        XCTAssertEqual(ExchangeInbox.unreadCount(page.threads), 2, "the unread pair is unchanged")
    }
}

// MARK: - 404: not available to this person

final class ConversationAvailabilityTests: XCTestCase {

    private func http(_ status: Int, _ code: String? = nil) -> Error {
        APIClient.APIError.http(status: status, code: code, message: nil)
    }

    /// A 404 — the spec's answer to anyone outside the audience — and only a
    /// 404, whatever its code.
    func testA404IsUnavailable() {
        XCTAssertTrue(ConversationAvailability.isUnavailable(http(404, "THREAD_NOT_FOUND")))
        XCTAssertTrue(ConversationAvailability.isUnavailable(http(404)), "a renamed code changes nothing")
    }

    /// Everything else stays the ordinary error state with its retry: a 403
    /// is a refusal the person can read, a 5xx or no network may pass.
    func testOtherFailuresAreNot() {
        XCTAssertFalse(ConversationAvailability.isUnavailable(http(403, "THREAD_NOT_A_PARTY")))
        XCTAssertFalse(ConversationAvailability.isUnavailable(http(500)))
        XCTAssertFalse(ConversationAvailability.isUnavailable(http(429)))
        XCTAssertFalse(ConversationAvailability.isUnavailable(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ConversationAvailability.isUnavailable(APIClient.APIError.notSignedIn))
    }

    /// Bulgarian, a full stop, no claim it was deleted and no colleague
    /// named — the server cannot tell which, and must not.
    func testTheStateSaysBothPossibilities() {
        let text = ConversationAvailability.message
        XCTAssertTrue(text.hasSuffix("."), text)
        XCTAssertTrue(text.contains("не е достъпен за Вас"), text)
        XCTAssertFalse(text.contains("изтрит"), text)
        XCTAssertFalse(text.lowercased().contains("колега"), text)
        XCTAssertEqual(ConversationAvailability.title, "Разговорът не е достъпен")
    }

    /// The conversation screen renders its own state for it, not `ErrorState`
    /// — read from the source, as there is no runtime hook into the switch.
    func testTheScreenHasItsOwnStateForIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/Exchange/ConversationView.swift"), encoding: .utf8)
        let unavailable = try XCTUnwrap(source.range(of: "if store.unavailable {"))
        let error = try XCTUnwrap(source.range(of: "ErrorState(message: failure)"),
                                  "positive control: the error state is still there")
        XCTAssertLessThan(unavailable.lowerBound, error.lowerBound,
                          "the 404 is decided before the generic failure")
        XCTAssertTrue(source.contains("ConversationAvailability.message"))
    }
}

// MARK: - Wording under the new semantics

final class PrivateConversationWordingTests: XCTestCase {

    /// The block refuses one PERSON since agri-saas #1397 (#186), and no
    /// string says «блокирахте това стопанство» — nor any longer that it
    /// stops «всички хора» at the other farm, which it does not. The seller
    /// side states the real scope as what happens; the inquirer side is true
    /// under either rule.
    func testNoStringSaysYouBlockedThisFarm() {
        let strings = ExchangeThreadRole.allCases.map(MessagingPolicy.blockedNotice(role:))
            + [MessagingPolicy.blockConfirmation, UserMessage.bulgarian["THREAD_BLOCKED"] ?? ""]
        for text in strings {
            XCTAssertFalse(text.lowercased().contains("това стопанство"), text)
            XCTAssertFalse(text.lowercased().contains("блокирали сте"), text)
            XCTAssertFalse(text.contains("всички хора"), "the farm-wide block is gone since #1397: \(text)")
            XCTAssertTrue(text.hasSuffix("."), text)
        }
        // Positive control: the scope IS said, on the side that can block —
        // wider than this conversation, and not the other farm's colleagues.
        XCTAssertTrue(MessagingPolicy.blockedNotice(role: .seller).contains("всички обяви"))
        XCTAssertTrue(MessagingPolicy.blockConfirmation.contains("всички обяви"))
        XCTAssertTrue(MessagingPolicy.blockConfirmation.contains("Другите хора от неговото стопанство все още могат"))
        // WHOM: the person who started the conversation, not «другата
        // страна» — two people can write on that side.
        for text in [MessagingPolicy.blockTitle, MessagingPolicy.blockConfirmation,
                     MessagingPolicy.blockedNotice(role: .seller)] {
            XCTAssertTrue(text.contains("човека, започнал разговора"), text)
        }
    }

    /// The person-level codes speak to the person; the farm-level ones still
    /// name the farm.
    func testPersonAndFarmAreSaidWhereTheServerChecksThem() {
        let bg = UserMessage.bulgarian
        XCTAssertEqual(bg["THREAD_NOT_FOUND"], "Разговорът не е намерен или не е достъпен за Вас.")
        XCTAssertEqual(bg["MESSAGE_NOT_SENDER"], "Можете да премахвате само съобщения, които сте изпратили Вие.")
        XCTAssertEqual(bg["THREAD_OWN_LISTING"], "Не можете да започнете разговор по обява на Вашето стопанство.")
    }
}

// MARK: - The badge, per person

@MainActor
final class PersonalUnreadTests: XCTestCase {
    /// A badge belongs to a farm, so these run with one open (#192).
    private var saved: Farm?

    /// The ASYNC overrides (#195): they take this class's main-actor
    /// isolation, which XCTest's synchronous `setUp`/`tearDown` can't.
    override func setUp() async throws {
        try await super.setUp()
        saved = ActiveFarm.shared.farm
        ActiveFarm.shared.set(Farm(slug: "ferma-1", name: nil))
    }

    override func tearDown() async throws {
        ActiveFarm.shared.set(saved)
        try await super.tearDown()
    }


    private func row(_ id: String, unread: Bool) -> ExchangeThreadSummary {
        ExchangeThreadSummary(id: id, listingId: "l", commodity: "wheat", listingRegionName: nil,
                              listingQuantityTonnes: nil, sellerDisplayName: nil, role: .seller,
                              lastMessageAt: Date(timeIntervalSince1970: 0), closed: false,
                              hasUnread: unread)
    }

    /// Two threads on one listing are counted as two — they are two people's
    /// conversations, and each can be unread on its own.
    func testTwoThreadsOnOneListingCountTwice() {
        let store = ExchangeUnreadStore()
        store.apply([row("a", unread: true), row("b", unread: true)],
                    asOf: SessionEpoch.current, farm: FarmPath.openSlug)
        XCTAssertEqual(store.count, 2)
        store.markedRead("a")
        XCTAssertEqual(store.count, 1, "reading one leaves the other")
    }

    /// A page fetched for the farm open a moment ago, landing after a switch,
    /// is not this farm's badge (agrent-ios#179).
    func testAPageFromTheFarmOpenBeforeIsDropped() {
        let saved = ActiveFarm.shared.farm
        defer { ActiveFarm.shared.set(saved) }
        ActiveFarm.shared.set(Farm(slug: "ferma-2", name: nil))
        let store = ExchangeUnreadStore()
        store.apply([row("a", unread: true)], asOf: SessionEpoch.current, farm: "ferma-2")
        XCTAssertEqual(store.count, 1, "positive control: this farm's page applies")
        store.reset()
        store.apply([row("a", unread: true), row("b", unread: true)],
                    asOf: SessionEpoch.current, farm: "ferma-1")
        XCTAssertEqual(store.count, 0, "the farm open a moment ago lent this one its badge")
    }
}
