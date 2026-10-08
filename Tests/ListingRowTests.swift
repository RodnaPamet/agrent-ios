import XCTest
@testable import Agrent

/// Борса's listing rows, from the A11yShots captures of 2026-10-08: where a
/// summary line may break, what a row says to VoiceOver, and which language
/// its region is in.
final class ListingRowTests: XCTestCase {

    private let nbsp = "\u{00A0}"

    private func listing(isOwn: Bool = true, quantity: String? = "250",
                         price: String? = "51.13", currency: String? = "EUR",
                         regionCode: String? = "BG-15", regionName: String? = "Pleven") -> ExchangeListing {
        ExchangeListing(
            id: "lst_test", side: .sell, kind: .culture, status: .active,
            commodity: "wheat", quantityTonnes: quantity, pricePerTonne: price,
            priceCurrency: currency, regionCode: regionCode, regionName: regionName,
            lat: nil, lon: nil, description: nil, sellerDisplayName: nil,
            createdAt: Date(timeIntervalSince1970: 0), expiresAt: nil, isOwn: isOwn
        )
    }

    private func line(_ listing: ExchangeListing, stacked: Bool) -> String {
        summary(side: listing.side, kind: listing.kind, quantity: listing.quantityTonnes,
                price: listing.pricePerTonne, currency: listing.priceCurrency, stacked: stacked)
    }

    // MARK: - Where a line may end

    /// AX5 drew «250 / т». Every space a line must not end at is no-break:
    /// inside each figure, and before each dot. The one ordinary space left
    /// in a figure is before the slash.
    func testANumberNeverEndsALineWithoutItsUnit() {
        XCTAssertEqual(
            line(listing(), stacked: false),
            "Продава\(nbsp)· Култура\(nbsp)· 250\(nbsp)т\(nbsp)· 51,13\(nbsp)EUR /\(nbsp)т"
        )
    }

    /// At the accessibility sizes the values take a line each and the dots
    /// go, as `MetaRow` and `MetaSeparator` do.
    func testAtTheAccessibilitySizesTheValuesStackAndTheDotsGo() {
        let stacked = line(listing(), stacked: true)
        XCTAssertEqual(stacked, "Продава\nКултура\n250\(nbsp)т\n51,13\(nbsp)EUR /\(nbsp)т")
        XCTAssertFalse(stacked.contains("·"), "a dot on a stacked line is a bullet on the wrong row")
    }

    /// A price with no currency is the amount and «/ т», with no gap where
    /// the currency would be. The old join left two spaces there.
    func testAPriceWithoutACurrencyLeavesNoGap() {
        for currency in [nil, ""] as [String?] {
            XCTAssertEqual(line(listing(quantity: nil, currency: currency), stacked: true),
                           "Продава\nКултура\n51,13 /\(nbsp)т", "currency \(String(describing: currency))")
        }
    }

    // MARK: - What the row says

    /// Everything the row prints, in its order, «ваша» second. It said the
    /// crop, the side and the region: no «ваша», no quantity, no price.
    func testTheBoardRowSaysWhatItPrints() {
        XCTAssertEqual(ListingRow.spoken(listing()),
                       "Пшеница, ваша, Продава, Култура, 250 тона, 51,13 евро на тон, Плевен.")
    }

    /// The currency as a word (#220) — the printed «EUR / т» is read out as
    /// letters and a slash. Trends' table, so the dollar counts and an
    /// unknown code stays a code; no currency leaves no gap.
    func testAPriceIsSpokenWithItsCurrencyAsAWord() {
        XCTAssertEqual(Exchange.spokenPrice("51.13", currency: "EUR"), "51,13 евро на тон")
        XCTAssertEqual(Exchange.spokenPrice("51.13", currency: "eur"), "51,13 евро на тон")
        XCTAssertEqual(Exchange.spokenPrice("512", currency: "USD"), "512,00 долара на тон")
        XCTAssertEqual(Exchange.spokenPrice("380", currency: "BGN"), "380,00 лева на тон")
        XCTAssertEqual(Exchange.spokenPrice("900", currency: "RON"), "900,00 RON на тон")
        XCTAssertEqual(Exchange.spokenPrice("51.13", currency: nil), "51,13 на тон")
        XCTAssertEqual(Exchange.spokenPrice("51.13", currency: ""), "51,13 на тон")
        XCTAssertNil(Exchange.spokenPrice(nil, currency: "EUR"))
    }

    /// «Моите обяви»: one stop per listing (#220), its status where the
    /// board says «ваша», and the same figures as words. Fixture row 0 is
    /// the expired 10 t at 50 EUR.
    func testMyListingIsOneStopSpokenFromTheValues() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "exchange-my-listings",
                                                           withExtension: "json"))
        let rows = try await APIClient.shared.decode(Data(contentsOf: url), as: [OwnExchangeListing].self)
        XCTAssertEqual(MyListingRow.spoken(rows[0]),
                       "Пшеница, Изтекла, Продава, Култура, 10 тона, 50,00 евро на тон.")
    }

    /// One tonne is «тон», as the inbox says it; another tenant's listing
    /// has no «ваша»; a figure the listing lacks is left out, not spoken as
    /// a gap.
    func testOneTonneAnotherTenantsRowAndAMissingPrice() {
        XCTAssertEqual(ListingRow.spoken(listing(isOwn: false, quantity: "1", price: nil)),
                       "Пшеница, Продава, Култура, 1 тон, Плевен.")
        XCTAssertEqual(Exchange.spokenTonnes("0.5"), "0,5 тона")
        XCTAssertEqual(Exchange.spokenTonnes("21"), "21 тона")
    }

    // MARK: - The region's language

    /// The wire's `regionName` is English; the label comes from the code,
    /// and the English only stands in for a code this build does not know.
    func testTheRegionIsBulgarianFromTheCode() {
        XCTAssertEqual(listing().region, "Плевен")
        XCTAssertEqual(listing(regionCode: "BG-18", regionName: "Ruse").region, "Русе")
        XCTAssertEqual(listing(regionCode: "BG-99", regionName: "Somewhere").region, "Somewhere")
        XCTAssertNil(listing(regionCode: nil, regionName: nil).region)
    }

    /// Nothing outside `Agrent/API/` reads the wire's English `regionName`
    /// except as `BulgarianRegion`'s `fallback:` — the board's rows and the
    /// listing's page printed it as sent, one screen along from where
    /// `BulgarianRegion` had already fixed it.
    ///
    /// No runtime hook says which property a view printed, so this reads the
    /// source, as `ListChromeTests` does, with a positive control.
    func testNoViewPrintsTheWireRegionName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Agrent")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !url.path.contains("/Agrent/API/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            hits += Self.wireRegionReads(in: text).map { "\(url.lastPathComponent): \($0)" }
        }
        XCTAssertGreaterThan(scanned, 50, "the walk found no sources")
        XCTAssertEqual(hits, [], "print `region`, not the wire's English `regionName`")

        // Positive control: the line the board had is caught; the map's
        // fallback, a comment and the inbox's own field are not.
        XCTAssertEqual(Self.wireRegionReads(in: """
            if let region = listing.regionName {
            BulgarianRegion.name(code: regionCode, fallback: listings.first?.regionName)
            // listing.regionName is English
            BulgarianRegion.name(english: thread.listingRegionName)
            """).count, 1)
    }

    private static func wireRegionReads(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.range(of: #"\.regionName\b"#, options: .regularExpression) != nil
                && !line.contains("fallback:")
        }
    }
}
