import XCTest
@testable import Agrent

/// «Публикувай от името на стопанството» (P6.7, agri-saas #1922; agrent-ios
/// #336): the listing's farm handle as the server resolves it, the field the
/// create sends, and where the phone offers either.
final class PublishAsFarmTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "\(name).json missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// Present on an attributed listing, nil on one that isn't, and nil
    /// when a server before #1922 doesn't send the field at all.
    func testAListingCarriesTheFarmHandleWhenAttributed() async throws {
        let page = try await APIClient.shared.decode(try fixture("exchange-listings"), as: ExchangeListingPage.self)
        XCTAssertEqual(page.rows.count, 2, "positive control: both synthetic rows decode")
        XCTAssertNil(page.rows[0].farmHandle, "row 0 predates the field")
        XCTAssertEqual(page.rows[1].farmHandle, "primerna-kooperatsiya")

        let json = #"{"rows":[{"id":"x","side":"SELL","kind":"CULTURE","status":"ACTIVE","commodity":"wheat","#
            + #""createdAt":"2026-10-15T09:00:00.000Z","isOwn":false,"farmHandle":null}],"nextCursor":null}"#
        let explicit = try await APIClient.shared.decode(Data(json.utf8), as: ExchangeListingPage.self)
        XCTAssertNil(explicit.rows.first?.farmHandle)
    }

    /// Sent only as `true`. Off, or for someone the flag is off for, the
    /// body carries no P6 field and the server's default (false) applies.
    func testTheCreateSendsPublishAsFarmOnlyWhenOn() throws {
        func body(_ publishAsFarm: Bool?) throws -> [String: Any] {
            let listing = CreateExchangeListing(
                side: "SELL", kind: "CULTURE", commodity: "wheat",
                quantityTonnes: 10, pricePerTonne: nil, regionCode: "BG-PVN", description: nil,
                sellerDisplayName: nil, sellerContact: nil, expiresAt: nil, publishAsFarm: publishAsFarm)
            let data = try JSONEncoder().encode(listing)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try body(true)["publishAsFarm"] as? Bool, true)
        XCTAssertNil(try body(nil)["publishAsFarm"])
        XCTAssertEqual(try body(nil)["commodity"] as? String, "wheat", "positive control: the body encodes")
    }

    /// The farm page a listing links to is `/f/{handle}`, the same as
    /// «Ферми»'s; no handle is no page.
    func testTheFarmPageIsThePublicProfile() throws {
        let page = try XCTUnwrap(InAppPage.farm(handle: "primerna-kooperatsiya"))
        XCTAssertEqual(page.url.path(), "/f/primerna-kooperatsiya")
        XCTAssertEqual(page.url, PublicProfileLink.url(handle: "primerna-kooperatsiya"))
        XCTAssertNil(InAppPage.farm(handle: nil))
    }

    /// Both ends behind the flag every P6 surface is behind: `/f/` answers
    /// only while it's on, and without a page the switch can't attribute
    /// anything. Read from the source, since the flag has no runtime hook in
    /// a unit test.
    func testBothEndsAreBehindTheFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let form = try source("Agrent/Exchange/NewListingView.swift")
        XCTAssertTrue(form.contains("struct NewListingView"), "positive control")
        let gate = try XCTUnwrap(form.range(of: "if flags.isOn(FarmBrandAPI.flag) {"))
        let toggle = try XCTUnwrap(form.range(of: #"Toggle("Публикувай от името на стопанството""#))
        XCTAssertLessThan(gate.lowerBound, toggle.lowerBound)
        XCTAssertTrue(form.contains("publishAsFarm: flags.isOn(FarmBrandAPI.flag) && publishAsFarm ? true : nil"))

        let detail = try source("Agrent/Exchange/ListingDetailView.swift")
        XCTAssertTrue(detail.contains("struct ListingDetailView"), "positive control")
        XCTAssertTrue(detail.contains(
            "if flags.isOn(FarmBrandAPI.flag), let page = InAppPage.farm(handle: shown.farmHandle) {"))
    }

    @MainActor
    func testTheSwitchSaysTheWebsCondition() {
        XCTAssertTrue(UserMessage.isBulgarianSentence(NewListingView.publishAsFarmNote))
        XCTAssertTrue(NewListingView.publishAsFarmNote.contains("анонимна"))
    }
}
