import SwiftUI
import UIKit
import XCTest
@testable import Agrent

/// Exchange messaging's SCREENS (agrent-ios#114, PARITY GAP 7): the rules the
/// inbox, the conversation, the composer and the listing button apply, pulled
/// into `MessagingPolicy` so they can be held here without a network.
///
/// Expectations are literals — the web's strings, the server's roles, the
/// owner's decisions of 2026-09-29 — never read back from the code under
/// test. Nothing here sends a request.
final class MessagingPollTests: XCTestCase {

    private func http(_ status: Int, retryAfter: Int? = nil) -> Error {
        APIClient.APIError.http(status: status, code: nil, message: nil,
                                retryAfterSeconds: retryAfter)
    }

    /// The web's cadences: 5 s for a conversation, 30 s for the inbox.
    func testTheCadencesAreTheWebs() {
        XCTAssertEqual(MessagingPolicy.conversationInterval, .seconds(5))
        XCTAssertEqual(MessagingPolicy.inboxInterval, .seconds(30))
    }

    func testASuccessWaitsTheInterval() {
        XCTAssertEqual(MessagingPolicy.nextPoll(after: nil, interval: .seconds(5)), .seconds(5))
    }

    /// A 429 waits what the server asked, instead of the interval.
    func testARateLimitWaitsTheServersTime() {
        XCTAssertEqual(MessagingPolicy.nextPoll(after: http(429, retryAfter: 42), interval: .seconds(5)),
                       .seconds(42))
    }

    /// With no header, the app's one fallback — a minute.
    func testARateLimitWithNoHeaderWaitsTheFallback() {
        XCTAssertEqual(MessagingPolicy.nextPoll(after: http(429), interval: .seconds(5)), .seconds(60))
    }

    /// A one-second `Retry-After` must not make the inbox poll FASTER.
    func testARateLimitNeverShortensTheInterval() {
        XCTAssertEqual(MessagingPolicy.nextPoll(after: http(429, retryAfter: 1), interval: .seconds(30)),
                       .seconds(30))
    }

    /// Anything else — a 503 with a header included — is an ordinary miss.
    func testOtherFailuresWaitTheInterval() {
        XCTAssertEqual(MessagingPolicy.nextPoll(after: http(503, retryAfter: 90), interval: .seconds(5)),
                       .seconds(5))
        XCTAssertEqual(MessagingPolicy.nextPoll(after: URLError(.notConnectedToInternet),
                                                interval: .seconds(30)),
                       .seconds(30))
    }
}

final class MessagingLabelTests: XCTestCase {

    /// Owner decision 1: the count in the segment's label, only when there
    /// is one.
    func testTheSegmentCarriesTheCountOnlyWhenThereIsOne() {
        XCTAssertEqual(MessagingPolicy.counted("Съобщения", unread: 0), "Съобщения")
        XCTAssertEqual(MessagingPolicy.counted("Съобщения", unread: 3), "Съобщения (3)")
        XCTAssertEqual(MessagingPolicy.counted("Борса", unread: 1), "Борса (1)")
    }

    /// The side IS known on a listing, so the button names the other party.
    func testTheListingButtonNamesTheOtherSide() {
        XCTAssertEqual(MessagingPolicy.messagePartyLabel(side: .sell).bulgarian, "Съобщение до продавача")
        XCTAssertEqual(MessagingPolicy.messagePartyLabel(side: .buy).bulgarian, "Съобщение до купувача")
        let unknown = MessagingPolicy.messagePartyLabel(side: .unknown).bulgarian
        XCTAssertFalse(unknown.contains("продавач") || unknown.contains("купувач"), unknown)
    }

    /// Voice Control listens in the device language: each name has English.
    func testTheListingButtonCanBeSaidInEnglish() {
        for side in ExchangeSide.allCases {
            let english = MessagingPolicy.messagePartyLabel(side: side).english
            XCTAssertTrue(english.allSatisfy(\.isASCII), english)
            XCTAssertFalse(english.isEmpty)
        }
    }

    /// The payloads carry no side, so the blocked notices name neither.
    func testTheBlockedNoticesAreSideNeutral() {
        for role in ExchangeThreadRole.allCases {
            let notice = MessagingPolicy.blockedNotice(role: role)
            XCTAssertFalse(notice.contains("купувач") || notice.contains("продавач"), notice)
            XCTAssertTrue(notice.hasSuffix("."), notice)
        }
        XCTAssertNotEqual(MessagingPolicy.blockedNotice(role: .seller),
                          MessagingPolicy.blockedNotice(role: .inquirer),
                          "the owner who blocked and the farm blocked read different things")
    }

    /// Near the limit only, and in the server's UTF-16 measure.
    func testTheCounterAppearsNearTheLimitOnly() {
        XCTAssertNil(MessagingPolicy.counter(for: "Здравейте"))
        let near = MessagingPolicy.counter(for: String(repeating: "а", count: 3600))
        XCTAssertEqual(near?.text, "3600 / 4000")
        XCTAssertEqual(near?.over, false)
        let over = MessagingPolicy.counter(for: String(repeating: "👍🏽", count: 1001))
        XCTAssertEqual(over?.text, "4004 / 4000", "four UTF-16 units each, as the server counts")
        XCTAssertEqual(over?.over, true)
    }
}

final class MessagingGatingTests: XCTestCase {

    private func user(_ role: String?) -> CurrentUser {
        CurrentUser(id: "u1", name: nil, email: nil, role: role)
    }

    /// `assertCanWrite` is ROLE_ORDER >= 3. Unknown fails OPEN — the server
    /// refuses, and its refusal is rendered.
    func testWritesAreOfferedToTheRolesThatCanWrite() {
        XCTAssertTrue(MessagingPolicy.mayWrite(nil), "unknown user fails open")
        XCTAssertTrue(MessagingPolicy.mayWrite(user("OWNER")))
        XCTAssertTrue(MessagingPolicy.mayWrite(user("ADMIN")))
        XCTAssertTrue(MessagingPolicy.mayWrite(user("EDITOR")))
        XCTAssertTrue(MessagingPolicy.mayWrite(user(nil)), "no role fails open")
        XCTAssertTrue(MessagingPolicy.mayWrite(user("SOMETHING_NEW")), "a new role fails open")
        XCTAssertFalse(MessagingPolicy.mayWrite(user("READER")))
        XCTAssertFalse(MessagingPolicy.mayWrite(user("auditor")), "case-insensitive")
        XCTAssertFalse(MessagingPolicy.mayWrite(user("MECHANISATOR")))
    }

    /// One list, not two: field operations and messaging gate identically.
    func testFieldOperationsAndMessagingAgree() {
        for role in ["OWNER", "READER", "AUDITOR", "MECHANISATOR", "EDITOR", nil] {
            XCTAssertEqual(user(role).mayCreateOperations, user(role).mayWrite, "\(role ?? "nil")")
        }
    }

    /// NOT tied to the listing being active — only to not being your own and
    /// to being able to write.
    func testTheListingButtonIgnoresTheListingsStatus() {
        XCTAssertTrue(MessagingPolicy.offersMessageParty(isOwn: false, mayWrite: true))
        XCTAssertFalse(MessagingPolicy.offersMessageParty(isOwn: true, mayWrite: true))
        XCTAssertFalse(MessagingPolicy.offersMessageParty(isOwn: false, mayWrite: false))
    }

    /// The block refuses the INQUIRER; the owner who set it can still write.
    func testABlockRefusesOnlyTheInquirer() {
        XCTAssertTrue(MessagingPolicy.refusedByBlock(role: .inquirer, blocked: true))
        XCTAssertFalse(MessagingPolicy.refusedByBlock(role: .seller, blocked: true))
        XCTAssertFalse(MessagingPolicy.refusedByBlock(role: .unknown, blocked: true))
        XCTAssertFalse(MessagingPolicy.refusedByBlock(role: .inquirer, blocked: false))
    }
}

final class ComposerTests: XCTestCase {

    private func canSend(_ draft: String, sending: Bool = false, paused: Bool = false,
                         refused: Bool = false) -> Bool {
        MessagingPolicy.canSend(draft: draft, sending: sending, paused: paused, refusedByBlock: refused)
    }

    func testSomethingToSayCanBeSent() {
        XCTAssertTrue(canSend("Здравейте"))
    }

    func testNothingToSayCannot() {
        XCTAssertFalse(canSend(""))
        XCTAssertFalse(canSend("  \n "))
    }

    /// 4000 UTF-16 units, trimmed — the server's limit, not the spec's 8000.
    func testTheLimitIsTheServers() {
        XCTAssertTrue(canSend(String(repeating: "а", count: 4000)))
        XCTAssertFalse(canSend(String(repeating: "а", count: 4001)))
        XCTAssertTrue(canSend("  " + String(repeating: "а", count: 4000) + "\n"))
    }

    /// One in flight at a time: the web's button accepts a second click.
    func testASendInFlightBlocksAnother() {
        XCTAssertFalse(canSend("Здравейте", sending: true))
    }

    /// The farm's budget is paused by a 429: nothing sends until it reopens.
    func testAPausedBudgetBlocksSending() {
        XCTAssertFalse(canSend("Здравейте", paused: true))
    }

    func testABlockThatRefusesThisFarmBlocksSending() {
        XCTAssertFalse(canSend("Здравейте", refused: true))
    }

    /// NOT the removed inquiry composer's `canSend`: there is no phase that a failure leaves
    /// behind. The same draft is sendable again as soon as nothing above
    /// holds it — which is what makes the kept key worth keeping.
    func testAFailedSendStaysSendable() {
        XCTAssertTrue(canSend("Здравейте", sending: false))
    }

    /// The draft goes on a 201 — unless the farmer typed on while it flew.
    func testTheDraftClearsOnlyWhenItWasWhatWasSent() {
        XCTAssertEqual(MessagingPolicy.draftAfterDelivery("Здравейте", sent: "Здравейте"), "")
        XCTAssertEqual(MessagingPolicy.draftAfterDelivery("  Здравейте \n", sent: "Здравейте"), "")
        XCTAssertEqual(MessagingPolicy.draftAfterDelivery("", sent: "Здравейте"), "")
        XCTAssertEqual(MessagingPolicy.draftAfterDelivery("Здравейте, и още", sent: "Здравейте"),
                       "Здравейте, и още")
    }

    /// A lost response is not a refusal. Saying «не е изпратено» after a
    /// timeout would be a claim the app cannot support — and pressing Send
    /// again is safe, because the retry replays the same key.
    func testAnUnknownOutcomeIsSaidAsUnknown() {
        for error: Error in [URLError(.timedOut), URLError(.networkConnectionLost),
                             APIClient.APIError.http(status: 502, code: nil, message: nil)] {
            XCTAssertTrue(MessagingPolicy.outcomeUnknown(error), "\(error)")
            XCTAssertTrue(MessagingPolicy.sendFailure(for: error).hasPrefix("Не е ясно"), "\(error)")
        }
    }

    /// A refusal is a refusal, with the server's reason in Bulgarian.
    func testARefusalSaysNotSentAndWhy() {
        let error = APIClient.APIError.http(status: 400, code: "MESSAGE_TOO_LONG", message: nil)
        XCTAssertFalse(MessagingPolicy.outcomeUnknown(error))
        let text = MessagingPolicy.sendFailure(for: error)
        XCTAssertTrue(text.hasPrefix("Съобщението не е изпратено."), text)
        XCTAssertTrue(text.contains(UserMessage.text(for: error)), text)
        XCTAssertFalse(MessagingPolicy.outcomeUnknown(URLError(.notConnectedToInternet)),
                       "no connection means the request never left")
    }

    /// What failed, then why — not the web's send failure for everything.
    func testAnActionFailureSaysWhatFailed() {
        let text = MessagingPolicy.failure("Разговорът не може да бъде затворен.",
                                           URLError(.notConnectedToInternet))
        XCTAssertEqual(text, "Разговорът не може да бъде затворен. Няма интернет връзка.")
    }
}

final class MessagingRetractTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A retract from SCROLLBACK: the refetch brings only the newest page,
    /// so the 200 has to make the tombstone where the message is.
    func testARetractTombstonesTheMessageInPlace() {
        let messages = ["a", "b", "c"].enumerated().map { index, id in
            ExchangeMessage(id: id, senderTenantId: nil, mine: true, body: "текст \(id)",
                            deleted: false, createdAt: t0.addingTimeInterval(Double(index)))
        }
        var conversation = Conversation(ExchangeThread(
            id: "t1", listingId: "l1", commodity: "wheat", role: .seller,
            lastMessageAt: t0, closed: false, blocked: false, unreadCount: nil,
            olderCursor: nil, messages: messages))

        conversation.tombstone("a")

        XCTAssertEqual(conversation.messages.map(\.id), ["a", "b", "c"], "it keeps its place")
        XCTAssertTrue(conversation.messages[0].isTombstone)
        XCTAssertNil(conversation.messages[0].body, "the text is gone from this phone too")
        XCTAssertFalse(conversation.messages[0].mayRetract, "and «Премахни» goes with it")
        XCTAssertEqual(conversation.messages[1].body, "текст b", "nothing else changes")
    }
}

@MainActor
final class UnreadBadgeTests: XCTestCase {

    private func row(_ id: String, unread: Bool) -> ExchangeThreadSummary {
        ExchangeThreadSummary(id: id, listingId: "l", commodity: "wheat", listingRegionName: nil,
                              listingQuantityTonnes: nil, sellerDisplayName: nil, role: .seller,
                              lastMessageAt: Date(timeIntervalSince1970: 0), closed: false,
                              hasUnread: unread)
    }

    /// Threads with `hasUnread`, and a mark lowers it at once — by the one
    /// thread, however many times.
    func testTheBadgeCountsThreadsAndDropsOnMark() {
        let store = ExchangeUnreadStore()
        store.apply([row("a", unread: true), row("b", unread: false), row("c", unread: true)],
                    asOf: SessionEpoch.current, farm: Config.tenantSlug)
        XCTAssertEqual(store.count, 2)
        store.markedRead("a")
        store.markedRead("a")
        XCTAssertEqual(store.count, 1)
        store.markedRead("b")
        XCTAssertEqual(store.count, 1, "marking a read thread changes nothing")
    }
}

final class InboxRegionTests: XCTestCase {

    /// The inbox row carries the English name and no code. Every English
    /// name the server stores (its `nameEn`, which the bundled geometry
    /// carries beside each code) comes out in Bulgarian.
    func testEveryOblastIsSaidInBulgarian() {
        XCTAssertEqual(BulgarianRegion.codesByEnglishName.count, 28,
                       "the bundled geometry is where the English names come from")
        for (english, code) in BulgarianRegion.codesByEnglishName {
            XCTAssertEqual(BulgarianRegion.name(english: english), BulgarianRegion.names[code], english)
        }
    }

    /// Literals, from agri-saas `bulgaria-regions.ts`: the two Sofias are two
    /// regions.
    func testTheTwoSofiasStayApart() {
        XCTAssertEqual(BulgarianRegion.name(english: "Sofia City"), "София (столица)")
        XCTAssertEqual(BulgarianRegion.name(english: "Sofia"), "София (област)")
        XCTAssertEqual(BulgarianRegion.name(english: "Pleven"), "Плевен")
        XCTAssertEqual(BulgarianRegion.name(english: " veliko tarnovo "), "Велико Търново")
    }

    /// Unknown stays as sent; nothing stays nothing.
    func testAnUnknownNameIsShownAsSent() {
        XCTAssertEqual(BulgarianRegion.name(english: "Atlantis"), "Atlantis")
        XCTAssertNil(BulgarianRegion.name(english: nil))
        XCTAssertNil(BulgarianRegion.name(english: "  "))
    }
}

/// The spoken names that must NOT collide with ones already on screen.
final class MessagingVocabularyTests: XCTestCase {

    /// `OutboxBanner`'s «Изпрати» / "Send" sits above every tab; the
    /// composer's send has to be a different name in both languages.
    func testTheComposersSendIsNotTheOutboxs() {
        XCTAssertTrue(Set(A11y.Spoken.sendMessage).isDisjoint(with: A11y.Spoken.send))
    }

    /// «Затвори» / "Close" leaves every sheet. Closing a conversation is seen
    /// by the other farm, so it must not answer to the way out.
    func testClosingAConversationIsNotLeavingASheet() {
        XCTAssertTrue(Set(A11y.Spoken.closeConversation).isDisjoint(with: A11y.Spoken.close))
    }
}

/// Properties with no runtime hook here, read from the source — each with a
/// positive control, so a moved file fails rather than passes.
final class MessagingSourceTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// NO DISK CACHE for another farm's words. The stores read straight from
    /// the network; `CachedResource` would put them in `ResponseCache`, which
    /// survives sign-out.
    func testMessagingIsNeverCached() throws {
        for path in ["Agrent/Exchange/MessagingStores.swift",
                     "Agrent/Exchange/ConversationView.swift",
                     "Agrent/Exchange/ExchangeInboxView.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("CachedResource."), path)
            XCTAssertFalse(text.contains("ResponseCache."), path)
        }
        XCTAssertTrue(try source("Agrent/Exchange/ExchangeStores.swift")
            .contains("CachedResource.loadShowingCacheFirst"),
                      "positive control: the listing stores ARE cached, and this probe sees it")
    }

    /// A body is plain text. `Text(message.body)` would be a `String` today
    /// and a markdown-parsing `LocalizedStringKey` the day somebody writes it
    /// as a literal interpolation.
    func testTheBodyIsRenderedVerbatim() throws {
        let text = try source("Agrent/Exchange/ConversationView.swift")
        XCTAssertTrue(text.contains("Text(verbatim: message.body"))
        XCTAssertFalse(text.contains("RichText("), "RichText is for the server's HTML notes")
    }

    /// The composer answers to its own name, not the outbox's.
    func testTheComposerIsNamedAsTheMessagesSend() throws {
        let text = try source("Agrent/Exchange/ConversationView.swift")
        XCTAssertTrue(text.contains("A11y.Spoken.sendMessage"))
        XCTAssertFalse(text.contains("A11y.Spoken.send)"))
        XCTAssertTrue(try source("Agrent/Core/OutboxBanner.swift")
            .contains(#"spokenNames("Изпрати", "Send")"#),
                      "positive control: the outbox's send is the name being avoided")
    }

    /// The send hands over the store's kept key, never `post`'s default.
    func testTheStoreSendsWithItsKeptKey() throws {
        let text = try source("Agrent/Exchange/MessagingStores.swift")
        XCTAssertTrue(text.contains("sendKeys.key(threadID: threadID, text: text)"))
        XCTAssertTrue(text.contains("idempotencyKey: key"))
        XCTAssertTrue(text.contains("sendKeys.delivered()"))
    }

    /// The listing's button is NOT gated on the listing being active — a
    /// closed listing is the way back to its conversation. Since the inquiry
    /// was removed (2026-10-01) the detail view has no `isActive` branch at
    /// all, so the check is that nothing in the file gates on it and that the
    /// button's only condition is `offersMessageParty`.
    func testTheListingButtonIsNotGatedOnTheListingBeingOpen() throws {
        let text = try source("Agrent/Exchange/ListingDetailView.swift")
        XCTAssertTrue(text.contains("if MessagingPolicy.offersMessageParty("),
                      "positive control: the button's condition moved")
        XCTAssertFalse(text.contains("listing.isActive"),
                       "the message button must not depend on the listing being open")
    }
}

/// The section picker, measured through the real control — UIKit draws the
/// segmented picker — in the simulator this suite runs in; not on a device.
@MainActor
final class ExchangeSectionPickerTests: XCTestCase {

    private func segmentedControls(size: DynamicTypeSize, unread: Int, width: CGFloat) -> Int {
        let root = ExchangeSectionPicker(selection: .constant(.browse), unread: unread)
            .padding(.horizontal)
            .environment(\.dynamicTypeSize, size)
            .environment(\.locale, Locale(identifier: "bg_BG"))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        return count(UISegmentedControl.self, in: host.view)
    }

    private func count<T: UIView>(_ type: T.Type, in view: UIView) -> Int {
        (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(type, in: $1) }
    }

    /// Where there is room the segments stay — the positive control that
    /// this probe can find a segmented control at all.
    func testAWideScreenKeepsTheSegments() {
        XCTAssertEqual(segmentedControls(size: .large, unread: 3, width: 1000), 1)
    }

    /// An iPhone 17 is 402pt wide; four Bulgarian segments ask for about 464.
    /// Truncated segments are what this replaces, so a phone gets the chips —
    /// with or without a count in the label.
    func testAPhoneGetsTheChipsRatherThanTruncatedSegments() {
        XCTAssertEqual(segmentedControls(size: .large, unread: 0, width: 402), 0)
        XCTAssertEqual(segmentedControls(size: .large, unread: 3, width: 402), 0)
    }

    /// At the accessibility sizes the chips are unconditional.
    func testTheAccessibilitySizesGetTheChips() {
        XCTAssertEqual(segmentedControls(size: .accessibility3, unread: 3, width: 1000), 0)
    }
}
