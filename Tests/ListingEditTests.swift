import XCTest
@testable import Agrent

/// The pencil on your own listing (#478, agri-saas #2543): the stored values
/// it starts from, the full-replacement body it sends, and the refusals it
/// names. Nothing here reaches the server.
@MainActor
final class ListingEditTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func rows() async throws -> [OwnExchangeListing] {
        try await APIClient.shared.decode(fixture("exchange-my-listings"), as: [OwnExchangeListing].self)
    }

    // MARK: - The stored values

    /// Decimals as the server writes them (strings, agri-saas #2555; a
    /// number would read too), exactly: 51.13 is not 51.130000000000003.
    func testTheEditObjectDecodesExactly() async throws {
        let all = try await rows()
        let active = try XCTUnwrap(all.first { $0.status == .active })
        let edit = try XCTUnwrap(active.edit)
        XCTAssertEqual(edit.side, .sell)
        XCTAssertEqual(edit.kind, .culture)
        XCTAssertEqual(edit.commodity, "wheat")
        XCTAssertEqual(edit.quantityTonnes.value, Decimal(250))
        XCTAssertEqual(edit.pricePerTonne?.value, Decimal(string: "51.13", locale: WireDecimal.wireLocale))
        XCTAssertEqual(edit.regionCode, "BG-15")
        XCTAssertEqual(edit.publishAsFarm, false)
        XCTAssertNotNil(edit.sellerContact, "the private contact comes back to its seller")
        XCTAssertNil(edit.expiresAt)
        XCTAssertEqual(edit.updatedAt, "2026-07-04T13:38:19.222Z", "the precondition is kept as the server's string")
    }

    func testTheListingsScreenCarriesIt() async throws {
        let all = try await rows()
        let own = try XCTUnwrap(all.first)
        XCTAssertEqual(ExchangeListing(own: own).edit, own.edit)
        XCTAssertNotNil(own.edit)
    }

    /// Before agri-saas #2543 there is no `edit`, and a malformed one costs
    /// the pencil, never the row.
    func testNoEditOrABrokenOneKeepsTheRow() async throws {
        let base = #"""
        {"id":"lst_synthetic","side":"SELL","kind":"CULTURE","commodity":"wheat","quantityTonnes":"10",
         "pricePerTonne":null,"priceCurrency":"EUR","regionCode":"BG-15","regionName":"Pleven","lat":null,
         "lon":null,"description":null,"sellerDisplayName":null,"status":"ACTIVE",
         "createdAt":"2026-10-31T10:00:00.000Z","expiresAt":null,"isOwn":true,"inquiries":[]
        """#
        let without = try await APIClient.shared.decode(Data((base + "}").utf8), as: OwnExchangeListing.self)
        XCTAssertNil(without.edit)
        let broken = try await APIClient.shared.decode(Data((base + #","edit":{"side":5}}"#).utf8),
                                                       as: OwnExchangeListing.self)
        XCTAssertNil(broken.edit)
        XCTAssertEqual(broken.id, "lst_synthetic")
    }

    // MARK: - The body

    private func body(_ update: UpdateExchangeListing) throws -> [String: Any] {
        let data = try JSONEncoder().encode(update)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A full replacement: every key, a cleared field as `null`, the switch
    /// as what it is, and `updatedAt` verbatim.
    func testTheBodySaysEveryFieldNullsIncluded() throws {
        let fields = CreateExchangeListing(
            side: "BUY", kind: "SEEDS", commodity: "maize", quantityTonnes: Decimal(string: "12.5")!,
            pricePerTonne: nil, regionCode: "BG-15", description: nil, sellerDisplayName: nil,
            sellerContact: nil, expiresAt: nil
        )
        let sent = try body(UpdateExchangeListing(fields: fields, publishAsFarm: true,
                                                   updatedAt: "2026-07-04T13:38:19.222Z"))
        XCTAssertEqual(Set(sent.keys), [
            "side", "kind", "commodity", "quantityTonnes", "pricePerTonne", "priceCurrency", "regionCode",
            "description", "sellerDisplayName", "publishAsFarm", "sellerContact", "expiresAt", "updatedAt",
        ])
        for cleared in ["pricePerTonne", "description", "sellerDisplayName", "sellerContact", "expiresAt"] {
            XCTAssertTrue(sent[cleared] is NSNull, "\(cleared) is said as null, not left out")
        }
        XCTAssertEqual(sent["publishAsFarm"] as? Bool, true)
        XCTAssertEqual(sent["priceCurrency"] as? String, "EUR")
        XCTAssertEqual(sent["updatedAt"] as? String, "2026-07-04T13:38:19.222Z")
        XCTAssertEqual((sent["quantityTonnes"] as? NSNumber)?.decimalValue, Decimal(string: "12.5"))
        XCTAssertEqual(sent["side"] as? String, "BUY")
    }

    func testTheBodyKeepsTheCreatesBounds() {
        let fields = CreateExchangeListing(
            side: "SELL", kind: "CULTURE", commodity: "wheat", quantityTonnes: 0, pricePerTonne: nil,
            regionCode: " ", description: nil, sellerDisplayName: nil, sellerContact: nil, expiresAt: nil
        )
        let update = UpdateExchangeListing(fields: fields, publishAsFarm: false, updatedAt: "x")
        XCTAssertEqual(update.problems, [.quantityOutOfRange, .regionMissing])
    }

    // MARK: - The form

    /// A stored number in the field: the comma a Bulgarian keyboard types,
    /// no grouping, so the form reads it straight back.
    func testAStoredNumberShowsAsTheFieldTakesIt() {
        XCTAssertEqual(NewListingView.fieldText(Decimal(string: "51.13", locale: WireDecimal.wireLocale)!), "51,13")
        XCTAssertEqual(NewListingView.fieldText(Decimal(250)), "250")
        XCTAssertEqual(NewListingView.fieldText(Decimal(string: "1000000", locale: WireDecimal.wireLocale)!), "1000000")
        XCTAssertEqual(NewListingView.fieldText(Decimal(string: "0.5", locale: WireDecimal.wireLocale)!), "0,5")
    }

    func testTheEditWordsAreBulgarian() {
        XCTAssertTrue(UserMessage.isBulgarianSentence(NewListingView.reactivationNote))
        XCTAssertTrue(UserMessage.isBulgarianSentence(NewListingView.editUnknownNote))
    }

    // MARK: - The status after a save

    /// An expired listing given a later date comes back ACTIVE, and its
    /// «Изпълнена» with it.
    func testAnEditsStatusIsTheScreens() {
        let custody = ListingCustody(status: .expired) { _, _ in
            XCTFail("adopting a status sends nothing")
            return ListingStatusChanged(id: "", status: .unknown)
        }
        XCTAssertEqual(ListingCustodyAction.offered(status: custody.status, isOwn: true, mayWrite: true), [.withdraw])
        custody.adopt(.active)
        XCTAssertEqual(ListingCustodyAction.offered(status: custody.status, isOwn: true, mayWrite: true),
                       [.fulfil, .withdraw])
    }

    // MARK: - The refusals, named

    /// agri-saas #2541/#2543: each refusal is its own code now, and each
    /// reads as a Bulgarian sentence rather than the code.
    func testEveryExchangeRefusalHasABulgarianSentence() {
        let codes = [
            "LISTING_TERMINAL", "LISTING_NOT_OWNED", "LISTING_MODIFIED", "LISTING_REGION_UNKNOWN",
            "LISTING_NOT_ACTIVE", "LISTING_EXPIRED", "LISTING_IS_YOUR_OWN", "INQUIRY_NOT_PENDING",
            "LISTING_EXPIRES_AT_IN_PAST", "LISTING_FULFIL_REQUIRES_ACTIVE", "INQUIRY_ACCEPT_REQUIRES_ACTIVE_LISTING",
        ]
        for code in codes {
            let text = UserMessage.text(for: APIClient.APIError.http(status: 400, code: code, message: code.lowercased()))
            XCTAssertTrue(UserMessage.isBulgarianSentence(text), "\(code): \(text)")
            XCTAssertFalse(text.contains(code.lowercased()), "\(code) shows the code")
        }
        // LISTING_MODIFIED is a 409 carrying its own code: not the optimistic
        // lock's STALE_DATA, so it reads as its sentence, never as a version clash.
        let modified = APIClient.conflict(from: Data(#"{"error":{"code":"LISTING_MODIFIED","message":"x"}}"#.utf8))
        XCTAssertTrue(UserMessage.text(for: modified).contains("променена, откакто я отворихте"), UserMessage.text(for: modified))
    }
}
