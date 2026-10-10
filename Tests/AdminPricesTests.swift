import XCTest
@testable import Agrent

/// Админ → «Цени» (#258), against agri-saas #1587 contract v1.1. NOTHING HERE
/// SENDS A PRICE: a typed price changes every farm's figures, so the body,
/// the key, the checks and the gate are pinned above the wire.
@MainActor
final class AdminPricesTests: XCTestCase {

    private func row(_ commodity: String, api: (Decimal, String)? = nil,
                     feed: AdminPricesAPI.Overrides.Feed = .ecAgrifood) throws -> AdminPricesAPI.Overrides.Row {
        let apiJSON = api.map { #"{"value":\#($0.0),"currency":"EUR","unit":"\#($0.1)","date":"2026-10-06","source":"x"}"# } ?? "null"
        let unit = commodity == "diesel" ? "EUR/l" : "EUR/t"
        let json = #"{"commodity":"\#(commodity)","typed":null,"api":\#(apiJSON),"apiFeed":"\#(feed.rawValue)","entryUnit":"\#(unit)","entryCurrency":"EUR"}"#
        return try JSONDecoder().decode(AdminPricesAPI.Overrides.Row.self, from: Data(json.utf8))
    }

    // MARK: - The read

    func testTheFixtureReadsAndTellsNoFeedFromNoCurrentPrice() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/admin-price-overrides.json")
        let overrides = try await APIClient.shared.decode(try Data(contentsOf: url), as: AdminPricesAPI.Overrides.self)
        XCTAssertEqual(overrides.commodities.count, 10)
        let maize = try XCTUnwrap(overrides.commodities.first { $0.commodity == "maize" })
        let map = try XCTUnwrap(overrides.commodities.first { $0.commodity == "map" })
        // Both have no API price; only one has no feed at all.
        XCTAssertNil(maize.api)
        XCTAssertNil(map.api)
        XCTAssertTrue(maize.apiFeed.exists)
        XCTAssertFalse(map.apiFeed.exists)
    }

    /// A feed this build has not heard of is a feed, not «none».
    func testAnUnknownFeedStillCountsAsAFeed() throws {
        let json = #"{"commodity":"oats","typed":null,"api":null,"apiFeed":"some-new-feed","entryUnit":"EUR/t","entryCurrency":"EUR"}"#
        let row = try JSONDecoder().decode(AdminPricesAPI.Overrides.Row.self, from: Data(json.utf8))
        XCTAssertEqual(row.apiFeed, .unknown)
        XCTAssertTrue(row.apiFeed.exists)
    }

    // MARK: - What would be sent

    /// Unit and currency are the server's to derive (#1587 §5d), so a body
    /// that named them could put a per-tonne figure into the litre series.
    func testTheDaySendsCommodityAndValueOnly() throws {
        let store = AdminPricesStore()
        store.day = try XCTUnwrap(BgDate.parseISODay("2026-10-10"))
        store.texts = ["diesel": "1,42", "wheat": "212 000,5", "barley": "  "]
        let day = store.draft
        XCTAssertEqual(day.date, "2026-10-10")
        // The form's order: crops first, then inputs; the blank field left out.
        XCTAssertEqual(day.prices.map(\.commodity), ["wheat", "diesel"])
        XCTAssertEqual(day.prices.map(\.value), [Decimal(string: "212000.5")!, Decimal(string: "1.42")!])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(day)) as? [String: Any])
        let first = try XCTUnwrap((body["prices"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["commodity", "value"])
    }

    func testAFigureThatIsNotAPositiveNumberIsRefused() {
        let store = AdminPricesStore()
        store.texts = ["wheat": "abc", "barley": "0", "maize": "-5", "sunflower": "450"]
        XCTAssertEqual(store.problems, ["wheat": .unreadable, "barley": .notPositive, "maize": .notPositive])
        XCTAssertFalse(store.canSave)
        store.texts = ["sunflower": "450"]
        XCTAssertTrue(store.canSave)
        // Nothing typed is nothing to save, not a problem.
        store.texts = [:]
        XCTAssertTrue(store.problems.isEmpty)
        XCTAssertFalse(store.canSave)
    }

    /// The same day retried dedupes on the server; a corrected one is a new
    /// write (`CostIdempotencyKey.mint`, now generic over the draft).
    func testARetryKeepsItsKeyAndACorrectionDoesNot() {
        let day = AdminPricesAPI.Day(date: "2026-10-10", prices: [.init(commodity: "wheat", value: 212)])
        let fixed = AdminPricesAPI.Day(date: "2026-10-10", prices: [.init(commodity: "wheat", value: 213)])
        let nonce = "6C4E0E84-8F9C-4F8E-9B0A-1D2C3E4F5A6B"
        XCTAssertEqual(CostIdempotencyKey.mint(nonce: nonce, draft: day), CostIdempotencyKey.mint(nonce: nonce, draft: day))
        XCTAssertNotEqual(CostIdempotencyKey.mint(nonce: nonce, draft: day), CostIdempotencyKey.mint(nonce: nonce, draft: fixed))
    }

    // MARK: - A second look before every farm sees it

    func testAFigureFarFromTheAPIIsFlagged() throws {
        let store = AdminPricesStore()
        let wheat = try row("wheat", api: (209, "EUR/t"))
        store.texts = ["wheat": "215"]
        XCTAssertFalse(store.isFarFromAPI(wheat))
        store.texts = ["wheat": "2150"]
        XCTAssertTrue(store.isFarFromAPI(wheat))
    }

    /// Diesel is typed per litre against a feed per 1000 l: compared through
    /// the exact ×1000, which catches the per-1000 slip.
    func testDieselIsComparedPerLitre() throws {
        let store = AdminPricesStore()
        let diesel = try row("diesel", api: (1395, "EUR/1000l"), feed: .oilBulletin)
        store.texts = ["diesel": "1,42"]
        XCTAssertFalse(store.isFarFromAPI(diesel))
        store.texts = ["diesel": "1420"]
        XCTAssertTrue(store.isFarFromAPI(diesel))
    }

    /// EUR/t against the World Bank's USD/mt has no rate here, so it is not
    /// compared at all rather than compared wrongly.
    func testNoComparisonAcrossCurrencies() throws {
        let store = AdminPricesStore()
        store.texts = ["urea": "9999"]
        XCTAssertFalse(store.isFarFromAPI(try row("urea", api: (395, "USD/mt"), feed: .worldBank)))
        XCTAssertNil(AdminPricesStore.factor(from: "EUR/t", to: "USD/mt"))
        XCTAssertEqual(AdminPricesStore.factor(from: "EUR/l", to: "EUR/1000l"), 1000)
    }

    // MARK: - Words

    /// Clearing a commodity with no feed leaves every calculator without a
    /// price for it; the confirmation says so rather than look like loss.
    func testClearingSaysWhatComesBack() throws {
        XCTAssertTrue(AdminPricesView.clearMessage(try row("wheat")).contains("от външния източник"))
        let rapeseed = try row("rapeseed", feed: .none)
        XCTAssertTrue(AdminPricesView.clearMessage(rapeseed).contains("Рапица няма външен източник"))
    }

    /// The unit comes off the payload (contract v1.2); the phone keeps no
    /// copy of which commodity is per litre.
    func testEachFieldNamesTheUnitTheServerSays() throws {
        XCTAssertEqual(try row("diesel", feed: .oilBulletin).entryUnit, "EUR/l")
        XCTAssertEqual(AdminPricesStore.unitLabel("EUR/t"), "€/т")
        XCTAssertEqual(AdminPricesStore.unitLabel("EUR/l"), "€/л")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Agrent/Admin/AdminPricesStore.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("row.entryUnit"), "positive control: the store reads the payload's unit")
        XCTAssertFalse(source.contains("== \"diesel\""), "the store kept its own copy of the per-litre split")
    }

    func testAClearPathCarriesTheSlugAsOneSegment() {
        XCTAssertTrue(AdminPricesAPI.clearPath("ammonium-nitrate").hasSuffix("/admin/market-prices/overrides/ammonium-nitrate"))
        XCTAssertTrue(AdminPricesAPI.clearPath("a/b").hasSuffix("/overrides/a%2Fb"))
    }

    // MARK: - Who is offered the screen

    /// The farm list's own row says which farm is the platform one, because
    /// `/api/auth/me` answers for the OLDEST membership (#1587 v1.1).
    func testOnlyThePlatformFarmsOwnerOrAdminIsOffered() {
        XCTAssertTrue(Farm(slug: "p", name: nil, role: "OWNER", isPlatform: true).offersPlatformPrices)
        XCTAssertTrue(Farm(slug: "p", name: nil, role: "ADMIN", isPlatform: true).offersPlatformPrices)
        XCTAssertFalse(Farm(slug: "p", name: nil, role: "MECHANISATOR", isPlatform: true).offersPlatformPrices)
        XCTAssertFalse(Farm(slug: "a", name: nil, role: "OWNER", isPlatform: false).offersPlatformPrices)
        // Not yet said, or a farm remembered before the flag existed: no.
        XCTAssertFalse(Farm(slug: "a", name: nil, role: "OWNER").offersPlatformPrices)
    }

    func testAFarmRowWithoutTheFlagReadsAsNotThePlatform() async throws {
        let json = #"{"farms":[{"slug":"a","name":"A","role":"OWNER"}]}"#
        let farms = try await FarmsAPI.decodeFarms(from: Data(json.utf8))
        XCTAssertNil(farms.first?.isPlatform)
        XCTAssertFalse(Farm(farms[0]).offersPlatformPrices)
    }

    // MARK: - The day refused (agri-saas #1618)

    /// Each of the four refusals says which crop, in Bulgarian, never the slug;
    /// without its params it still says something true.
    func testTheDaysRefusalsNameTheCropInBulgarian() {
        func said(_ code: String, _ params: [String: String]? = nil) -> String {
            UserMessage.httpText(status: 400, code: code, message: "English fallback.", params: params)
        }
        XCTAssertEqual(said("DUPLICATE_COMMODITY", ["commodity": "wheat"]),
                       "Цената на „\(CommodityName.canonical("wheat")!)“ е въведена два пъти за един ден.")
        XCTAssertEqual(said("UNKNOWN_COMMODITY", ["commodity": "wheat"]),
                       "Сървърът не разпознава „\(CommodityName.canonical("wheat")!)“.")
        XCTAssertEqual(said("COMMODITY_NOT_OVERRIDABLE", ["commodity": "oats"]),
                       "За „\(CommodityName.canonical("oats")!)“ не се въвежда цена от тук.")
        XCTAssertEqual(said("OVERRIDE_DENOMINATION_CHANGED",
                            ["commodity": "diesel", "stored": "EUR EUR/t", "expected": "EUR EUR/l"]),
                       "Цената на „\(CommodityName.canonical("diesel")!)“ е въведена в EUR/t, "
                       + "а вече се въвежда в EUR/l. Изчистете я, преди да въведете нова.")
        for code in ["DUPLICATE_COMMODITY", "UNKNOWN_COMMODITY", "COMMODITY_NOT_OVERRIDABLE",
                     "OVERRIDE_DENOMINATION_CHANGED"] {
            let bare = said(code)
            XCTAssertNotEqual(bare, "English fallback.", code)
            XCTAssertTrue(bare.hasSuffix("."), code)
            XCTAssertFalse(bare.contains("_"), code)
        }
    }
}
