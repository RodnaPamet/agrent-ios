import XCTest
@testable import Agrent

/// Decoded against bytes captured off the live wire on 2026-09-21, not
/// against a description. Both fixtures are real production responses with
/// identifiers scrubbed.
final class ExchangeModelsTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        else {
            XCTFail("\(name).json missing from the test bundle")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    // MARK: - The two endpoints disagree on envelope

    /// `listings` answers an envelope. `my-listings` answers a bare array.
    /// Decoding either shape with the other's type fails outright, so this
    /// pins both — it is the journal's `{rows}`-vs-array situation again, and
    /// that one cost a day.
    func testListingsIsAnEnvelope() async throws {
        let page = try await APIClient.shared.decode(
            fixture("exchange-listings"), as: ExchangeListingPage.self
        )
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertNil(page.nextCursor)
    }

    func testMyListingsIsABareArray() async throws {
        let rows = try await APIClient.shared.decode(
            fixture("exchange-my-listings"), as: [OwnExchangeListing].self
        )
        XCTAssertEqual(rows.count, 2)
    }

    func testEachEndpointRejectsTheOthersShape() async throws {
        let listings = try fixture("exchange-listings")
        let mine = try fixture("exchange-my-listings")
        var envelopeFromArray: ExchangeListingPage?
        var arrayFromEnvelope: [OwnExchangeListing]?
        envelopeFromArray = try? await APIClient.shared.decode(mine, as: ExchangeListingPage.self)
        arrayFromEnvelope = try? await APIClient.shared.decode(listings, as: [OwnExchangeListing].self)
        XCTAssertNil(envelopeFromArray, "a bare array must not decode as an envelope")
        XCTAssertNil(arrayFromEnvelope, "an envelope must not decode as a bare array")
    }

    // MARK: - Decimals arrive as strings

    /// `quantityTonnes` and `pricePerTonne` are JSON STRINGS, not numbers —
    /// Prisma Decimal serialisation. Typing either as Double fails the whole
    /// payload, and would also introduce binary rounding into a price.
    func testDecimalsAreStringsAndParseExactly() async throws {
        let page = try await APIClient.shared.decode(
            fixture("exchange-listings"), as: ExchangeListingPage.self
        )
        let row = try XCTUnwrap(page.rows.first)

        XCTAssertEqual(row.quantityTonnes, "250")
        XCTAssertEqual(row.pricePerTonne, "51.13")

        XCTAssertEqual(row.quantity, Decimal(string: "250"))
        XCTAssertEqual(row.price, Decimal(string: "51.13"))

        // Exactness is the reason for Decimal over Double: the raw string
        // round-trips, which a binary float cannot promise for 51.13.
        XCTAssertEqual("\(try XCTUnwrap(row.price))", "51.13")
    }

    // MARK: - Dates here ARE dates

    /// Unlike the calculator's `priceObservedAt` (yyyy-mm-dd, a String), these
    /// are full ISO 8601 with fractional seconds, which the app's decoder
    /// accepts — so they are genuinely `Date`. The distinction is per field,
    /// not per payload.
    func testTimestampsDecodeAsDates() async throws {
        let page = try await APIClient.shared.decode(
            fixture("exchange-listings"), as: ExchangeListingPage.self
        )
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(
            row.createdAt,
            ISO8601DateFormatter.testParse("2026-07-04T13:38:19.222Z")
        )
        XCTAssertNil(row.expiresAt, "null expiry must stay nil, not become a date")

        let mine = try await APIClient.shared.decode(
            fixture("exchange-my-listings"), as: [OwnExchangeListing].self
        )
        XCTAssertNotNil(mine.first?.expiresAt, "this row does have an expiry")
    }

    // MARK: - Cross-tenant visibility

    /// The table is GLOBAL with no tenantId and no RLS, by design — every
    /// tenant sees every ACTIVE listing, and `isOwn` is the only thing
    /// separating yours. A UI that assumes tenant filtering because the URL
    /// carries a slug would be wrong about what it is showing.
    func testIsOwnIsTheOnlyOwnershipMarker() async throws {
        let page = try await APIClient.shared.decode(
            fixture("exchange-listings"), as: ExchangeListingPage.self
        )
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertTrue(row.isOwn)
        XCTAssertEqual(row.status, .active)
        XCTAssertTrue(row.isActive)
        XCTAssertEqual(row.side, .sell)
        XCTAssertEqual(row.kind, .culture)
    }

    // MARK: - Vocabularies

    /// Written out literally from prisma/schema/enums.prisma rather than
    /// derived from allCases — a test generated from the thing it checks
    /// cannot detect a change to it.
    func testServerVocabulariesDecode() throws {
        func parse<T: Decodable>(_ raw: String, as type: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: Data("\"\(raw)\"".utf8))
        }
        XCTAssertEqual(try parse("SELL", as: ExchangeSide.self), .sell)
        XCTAssertEqual(try parse("BUY", as: ExchangeSide.self), .buy)

        let kinds: [(String, ExchangeKind)] = [
            ("CULTURE", .culture), ("FERTILIZER", .fertilizer),
            ("SEEDS", .seeds), ("PRODUCT", .product),
        ]
        for (raw, expected) in kinds {
            XCTAssertEqual(try parse(raw, as: ExchangeKind.self), expected)
        }

        let statuses: [(String, ExchangeListingStatus)] = [
            ("ACTIVE", .active), ("FULFILLED", .fulfilled),
            ("WITHDRAWN", .withdrawn), ("EXPIRED", .expired),
        ]
        for (raw, expected) in statuses {
            XCTAssertEqual(try parse(raw, as: ExchangeListingStatus.self), expected)
        }

        let inquiry: [(String, ExchangeInquiryStatus)] = [
            ("PENDING", .pending), ("ACCEPTED", .accepted), ("DECLINED", .declined),
        ]
        for (raw, expected) in inquiry {
            XCTAssertEqual(try parse(raw, as: ExchangeInquiryStatus.self), expected)
        }
    }

    /// The LogEntryType lesson, enforced: an unrecognised value costs a vague
    /// label on one field and the ROW STILL DECODES around it.
    func testUnknownVocabularyValueDoesNotFailTheRow() async throws {
        let json = Data("{\"rows\":[{\"id\":\"lst_1\",\"side\":\"BARTER\",\"kind\":\"LIVESTOCK\",\"status\":\"SOMETHING_NEW\",\"commodity\":\"wheat\",\"quantityTonnes\":\"1\",\"pricePerTonne\":\"2\",\"priceCurrency\":\"EUR\",\"regionCode\":null,\"regionName\":null,\"lat\":null,\"lon\":null,\"description\":null,\"sellerDisplayName\":null,\"createdAt\":\"2026-07-04T13:38:19.222Z\",\"expiresAt\":null,\"isOwn\":false}],\"nextCursor\":null}".utf8)
        let page = try await APIClient.shared.decode(json, as: ExchangeListingPage.self)
        let listing = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(listing.side, .unknown)
        XCTAssertEqual(listing.kind, .unknown)
        XCTAssertEqual(listing.status, .unknown)
        XCTAssertEqual(listing.commodity, "wheat", "the rest of the row survived")
        XCTAssertFalse(listing.isActive)
    }

    func testEveryVocabularyCaseHasALabel() {
        for v in ExchangeSide.allCases { XCTAssertFalse(v.label.isEmpty) }
        for v in ExchangeKind.allCases { XCTAssertFalse(v.label.isEmpty) }
        for v in ExchangeListingStatus.allCases { XCTAssertFalse(v.label.isEmpty) }
        for v in ExchangeInquiryStatus.allCases { XCTAssertFalse(v.label.isEmpty) }
    }

    // MARK: - Inquiries

    /// Every observed `inquiries` array was empty, so the element type is
    /// unverified. Lenient decoding means a surprise there costs the seller a
    /// missing row, not the page they need in order to withdraw a listing.
    func testMalformedInquiryIsDroppedNotFatal() throws {
        let json = Data("""
        {"id":"lst_1","side":"SELL","kind":"CULTURE","status":"ACTIVE",
         "commodity":"wheat","quantityTonnes":"1","pricePerTonne":"2",
         "priceCurrency":"EUR","regionCode":null,"regionName":null,
         "lat":null,"lon":null,"description":null,"sellerDisplayName":null,
         "createdAt":"2026-07-04T13:38:19.222Z","expiresAt":null,"isOwn":true,
         "inquiries":[{"nope":1},{"id":"inq_1","status":"PENDING"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(OwnExchangeListing.self, from: json)
        XCTAssertEqual(row.inquiries.count, 1)
        XCTAssertEqual(row.inquiries.first?.id, "inq_1")
        XCTAssertEqual(row.inquiries.first?.status, .pending)
    }

    /// `contactSharedAt` is the enforcement point, so a nil one must read as
    /// "not shared" rather than as missing data to paper over.
    func testContactIsNotSharedUntilTimestampExists() throws {
        let json = Data(#"{"id":"inq_1","status":"PENDING"}"#.utf8)
        let inquiry = try JSONDecoder().decode(ExchangeInquiry.self, from: json)
        XCTAssertFalse(inquiry.contactShared)
        XCTAssertNil(inquiry.contactSharedAt)
    }
}

private extension ISO8601DateFormatter {
    static func testParse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}
