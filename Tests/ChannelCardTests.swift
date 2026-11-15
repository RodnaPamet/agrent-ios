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
        XCTAssertNil(listing.card.flatMap(CardFace.init), "no commodity or quantity: the body shows")
        let unknown = try await post(#"{"kind":"POLL","payload":{"title":"t"}}"#)
        XCTAssertNil(unknown.card.flatMap(CardFace.init), "an unknown kind: the body shows")
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

    // MARK: - LISTING, SCHEME, EVENT (agri-saas #3084)

    func testAListingSaysCropAndTonnesAndPriceOnlyWithItsCurrency() async throws {
        let priced = try await post(#"{"kind":"LISTING","payload":{"region":"BG-16","listingId":"l1","commodity":"wheat","side":"SELL","quantityTonnes":"25.000","pricePerTonne":"188.65","priceCurrency":"EUR"}}"#)
        let face = try XCTUnwrap(priced.card.flatMap(CardFace.init))
        XCTAssertEqual(face.heading, "Обяви")
        XCTAssertEqual(face.line, "\(CommodityName.canonical("wheat") ?? ""), 25 т — 188,65 EUR/т")
        XCTAssertEqual(face.listingID, "l1")
        XCTAssertNil(face.link)

        let noCurrency = try await post(#"{"kind":"LISTING","payload":{"listingId":"l2","commodity":"maize","quantityTonnes":"12.5","pricePerTonne":"200.00","priceCurrency":null}}"#)
        XCTAssertEqual(noCurrency.card.flatMap(CardFace.init)?.line, "\(CommodityName.canonical("maize") ?? ""), 12,5 т",
                       "a price with no currency is left out, and no dash dangles")
        XCTAssertEqual(ChannelWords.decimal("25.000", fraction: 0...3), "25", "through Decimal: the stored digits")
    }

    func testASchemeSaysItsDeadlineOnlyWhenItHasOne() async throws {
        let dated = try await post(#"{"kind":"SCHEME","payload":{"schemeId":"s1","title":"Интервенция за млади земеделци","authority":"ДФЗ","opensOn":"2026-11-01","closesOn":"2026-12-01","url":"https://dfz.bg/x"}}"#)
        let face = try XCTUnwrap(dated.card.flatMap(CardFace.init))
        XCTAssertEqual(face.heading, "Подпомагане")
        XCTAssertEqual(face.line, "Интервенция за млади земеделци")
        XCTAssertEqual(face.details.first, "ДФЗ")
        XCTAssertTrue(face.details.last?.hasPrefix("Краен срок: 1 декември 2026") ?? false, face.details.description)
        let undated = try await post(#"{"kind":"SCHEME","payload":{"schemeId":"s2","title":"Обявление","authority":null,"closesOn":null,"url":null}}"#)
        XCTAssertEqual(undated.card.flatMap(CardFace.init)?.details, [], "never an empty «Краен срок:»")
    }

    func testAnEventSaysWhenAndWhere() async throws {
        let event = try await post(#"{"kind":"EVENT","payload":{"eventId":"e1","title":"Изложение Агра","category":"fair","startsAt":"2026-03-03T08:00:00.000Z","endsAt":null,"place":"Пловдив","url":"https://example.org/agra"}}"#)
        let face = try XCTUnwrap(event.card.flatMap(CardFace.init))
        XCTAssertEqual(face.heading, "Събития")
        XCTAssertEqual(face.line, "Изложение Агра")
        XCTAssertTrue(face.details.first?.hasPrefix("Начало: 3 март") ?? false, face.details.description)
        XCTAssertEqual(face.details.last, "Пловдив")
        XCTAssertEqual(face.link?.absoluteString, "https://example.org/agra")
    }
}
