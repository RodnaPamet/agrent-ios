import XCTest
@testable import Agrent

/// Machine-written channel cards (P9.4, #629): NEWS drawn from its facts,
/// everything else left to the plain-text body. Synthetic posts.
final class ChannelCardTests: XCTestCase {

    private func post(_ card: String, deleted: Bool = false) async throws -> ChannelPost {
        try await APIClient.shared.decode(Data("""
        {"id":"p1","authorUserId":"system","body":"Новини: Цените на пшеницата растат","kind":"CARD",
         "createdAt":"2026-11-15T09:00:00.000Z","deleted":\(deleted),"resolvedAt":null,"replyCount":0,"card":\(card)}
        """.utf8), as: ChannelPost.self)
    }

    func testANewsCardReadsItsFacts() async throws {
        let read = try await post(#"{"kind":"NEWS","payload":{"tag":"market","title":"Цените на пшеницата растат","url":"https://example.org/a","source":"Пример","publishedAt":"2026-11-15T08:00:00.000Z"}}"#)
        let news = try XCTUnwrap(read.card?.news)
        XCTAssertEqual(news.title, "Цените на пшеницата растат")
        XCTAssertEqual(news.link?.absoluteString, "https://example.org/a")
        XCTAssertEqual(ChannelWords.newsSource(news.source ?? ""), "Източник: Пример")
        XCTAssertEqual(ChannelWords.newsHeading, "Новини")
        XCTAssertEqual(ChannelWords.cardOpen, "Отвори")
    }

    /// Anything else stays the body: an unknown kind, an unreadable payload,
    /// no card, a hidden card.
    func testEverythingElseFallsBackToTheBody() async throws {
        let listing = try await post(#"{"kind":"LISTING","payload":{"listingId":"l1"}}"#)
        XCTAssertEqual(listing.card?.kind, "LISTING")
        XCTAssertNil(listing.card?.news, "not drawn yet: the body shows")
        let untitled = try await post(#"{"kind":"NEWS","payload":{"url":"x"}}"#)
        XCTAssertNil(untitled.card?.news, "no title, no card")
        let plain = try await post("null")
        XCTAssertNil(plain.card)
        let removed = try await post(#"{"kind":"NEWS","payload":{"title":"t"}}"#, deleted: true)
        XCTAssertNil(removed.card, "a removed post serves nothing through the card either")
        XCTAssertEqual(listing.body, "Новини: Цените на пшеницата растат", "positive control: the body is kept")
    }

    func testOnlyAWebAddressOpens() async throws {
        let odd = try await post(#"{"kind":"NEWS","payload":{"title":"t","url":"javascript:alert(1)"}}"#)
        XCTAssertNil(odd.card?.news?.link)
    }
}
