import CoreGraphics
import XCTest
@testable import Agrent

/// The bundled geometry, and the projection it declares.
final class BulgariaMapTests: XCTestCase {

    private var map: BulgariaMap {
        guard let m = BulgariaMap.bundled() else {
            fatalError("bg-map-geometry.json is not in the bundle")
        }
        return m
    }

    /// 28 oblasti, and the asset must actually ship. A map that silently
    /// has no geometry renders an empty country.
    func testTheAssetIsBundledAndComplete() {
        XCTAssertEqual(map.oblasti.count, 28)
        XCTAssertEqual(map.width, 1000)
        XCTAssertEqual(map.height, 600)
        XCTAssertFalse(map.outline.isEmpty)
    }

    /// Every polygon has an ISO code, and every code has a Bulgarian name.
    /// The join was verified server-side both ways; this asserts the half
    /// that can be checked here, so a region cannot render nameless.
    func testEveryOblastHasACodeAndABulgarianName() {
        for oblast in map.oblasti {
            XCTAssertTrue(oblast.iso.hasPrefix("BG-"), oblast.iso)
            XCTAssertGreaterThanOrEqual(oblast.points.count, 3, oblast.iso)
            let name = BulgarianRegion.name(code: oblast.iso)
            XCTAssertNotNil(name)
            XCTAssertNotEqual(name, oblast.iso, "\(oblast.iso) has no Bulgarian name")
            XCTAssertTrue(
                name!.unicodeScalars.contains { $0.value > 0x400 },
                "\(oblast.iso) → \(name!) is not Bulgarian")
        }
    }

    func testTheCatalogueIsExactlyTwentyEight() {
        XCTAssertEqual(BulgarianRegion.names.count, 28)
        let codes = Set(map.oblasti.map(\.iso))
        XCTAssertEqual(codes, Set(BulgarianRegion.names.keys),
                       "geometry and catalogue disagree about the oblast set")
    }

    /// THE projection check. Verified against the file's own declared
    /// bounds: projecting the corners must land on the bounding box of the
    /// actual path points, x 51.8…948.2 and y 10.0…590.0.
    ///
    /// This is what makes a listing's lat/lon land in the same space as
    /// the polygons rather than near it.
    func testTheProjectionMatchesTheGeometry() {
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for oblast in map.oblasti {
            for p in oblast.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        // North-west and south-east corners of the declared bounds.
        let nw = map.point(lat: 44.21002, lon: 22.3482)
        let se = map.point(lat: 41.23384, lon: 28.60972)
        XCTAssertEqual(nw.x, minX, accuracy: 1.0)
        XCTAssertEqual(nw.y, minY, accuracy: 1.0)
        XCTAssertEqual(se.x, maxX, accuracy: 1.0)
        XCTAssertEqual(se.y, maxY, accuracy: 1.0)
    }

    /// North is UP. A sign error here draws Bulgaria upside down and
    /// every marker in the wrong oblast — visibly wrong to anyone who
    /// knows the country and invisible to a test that only checks extents.
    func testNorthIsUp() {
        let north = map.point(lat: 44.0, lon: 25.0)
        let south = map.point(lat: 42.0, lon: 25.0)
        XCTAssertLessThan(north.y, south.y)
        let west = map.point(lat: 43.0, lon: 23.0)
        let east = map.point(lat: 43.0, lon: 27.0)
        XCTAssertLessThan(west.x, east.x)
    }

    /// The parser handles exactly M, L and Z — measured as the whole
    /// command set across all 28 paths and the outline.
    func testPathParsing() {
        XCTAssertEqual(BulgariaMap.parse("M10 20L30 40Z"),
                       [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)])
        // A minus begins a new number without a separator, which is how
        // these paths encode negatives.
        XCTAssertEqual(BulgariaMap.parse("M1.5-2.5L-3 4"),
                       [CGPoint(x: 1.5, y: -2.5), CGPoint(x: -3, y: 4)])
        XCTAssertTrue(BulgariaMap.parse("").isEmpty)
        // An odd number of coordinates drops the incomplete pair rather
        // than inventing one.
        XCTAssertEqual(BulgariaMap.parse("M1 2L3").count, 1)
    }
}

/// EVERY AGGREGATE IS WITHIN A SINGLE CURRENCY OR IT DOES NOT EXIST.
/// Averaging 200 EUR/t with 380 BGN/t gives 290 of nothing — a confident
/// number that is not a price in any currency, on the screen a farmer uses
/// to decide what to sell for.
final class RegionAggregateTests: XCTestCase {

    private func listing(
        _ id: String, region: String?, price: String?, currency: String?,
        lat: Double? = 43.0, lon: Double? = 25.0
    ) -> ExchangeListing {
        ExchangeListing(
            id: id, side: .sell, kind: .culture, status: .active,
            commodity: "wheat", quantityTonnes: "100", pricePerTonne: price,
            priceCurrency: currency, regionCode: region, regionName: "Plovdiv",
            lat: lat, lon: lon, description: nil, sellerDisplayName: nil,
            createdAt: Date(), expiresAt: nil, isOwn: false
        )
    }

    /// THE test. Two currencies produce TWO figures, never one.
    func testTwoCurrenciesAreNeverBlended() {
        let region = RegionAggregate(regionCode: "BG-16", listings: [
            listing("1", region: "BG-16", price: "200", currency: "EUR"),
            listing("2", region: "BG-16", price: "380", currency: "BGN"),
        ])
        XCTAssertEqual(region.prices.count, 2)
        XCTAssertTrue(region.isMixedCurrency)
        // And no figure is the average of the two.
        let blended = Decimal(290)
        for price in region.prices {
            XCTAssertNotEqual(price.average, blended)
        }
    }

    /// A lone offer in a third currency keeps its own label and takes no
    /// part in the comparison.
    func testALoneForeignOfferIsNotAbsorbed() {
        let region = RegionAggregate(regionCode: "BG-16", listings: [
            listing("1", region: "BG-16", price: "200", currency: "EUR"),
            listing("2", region: "BG-16", price: "210", currency: "EUR"),
            listing("3", region: "BG-16", price: "900", currency: "USD"),
        ])
        let eur = region.prices.first { $0.currency == "EUR" }
        XCTAssertEqual(eur?.count, 2)
        XCTAssertEqual(eur?.high, Decimal(210), "the USD offer leaked into the EUR range")
        XCTAssertEqual(region.prices.first { $0.currency == "USD" }?.count, 1)
    }

    /// One currency averages normally — the rule is about mixing, not
    /// about refusing to compute.
    func testASingleCurrencyAverages() {
        let region = RegionAggregate(regionCode: "BG-16", listings: [
            listing("1", region: "BG-16", price: "100", currency: "EUR"),
            listing("2", region: "BG-16", price: "200", currency: "EUR"),
        ])
        XCTAssertEqual(region.prices.count, 1)
        XCTAssertFalse(region.isMixedCurrency)
        XCTAssertEqual(region.prices[0].average, Decimal(150))
        XCTAssertEqual(region.prices[0].low, Decimal(100))
        XCTAssertEqual(region.prices[0].high, Decimal(200))
    }

    /// "200 – 200" reads as an uncertainty that is not there.
    func testOneOfferIsNotARange() {
        let region = RegionAggregate(regionCode: "BG-16", listings: [
            listing("1", region: "BG-16", price: "200", currency: "EUR"),
        ])
        XCTAssertTrue(region.prices[0].isSinglePrice)
    }

    /// A listing with no price is counted but does not distort the range.
    func testAPricelessListingStillCounts() {
        let region = RegionAggregate(regionCode: "BG-16", listings: [
            listing("1", region: "BG-16", price: nil, currency: nil),
            listing("2", region: "BG-16", price: "200", currency: "EUR"),
        ])
        XCTAssertEqual(region.count, 2)
        XCTAssertEqual(region.prices.first?.count, 1)
    }

    /// Unplaceable listings are DROPPED from the map and surfaced
    /// separately. Silently omitting them makes the map claim a
    /// completeness it does not have.
    func testListingsWithoutCoordinatesAreExcludedAndCounted() {
        let all = [
            listing("1", region: "BG-16", price: "200", currency: "EUR"),
            listing("2", region: nil, price: "200", currency: "EUR"),
            listing("3", region: "BG-16", price: "200", currency: "EUR", lat: nil, lon: nil),
        ]
        XCTAssertEqual(RegionAggregate.group(all).first?.count, 1)
        XCTAssertEqual(RegionAggregate.unplaceable(all).count, 2)
    }

    /// The label is the CATALOGUE's, never the wire's `regionName`, which
    /// is English — the `{commodity}` defect in a third place.
    func testTheNameIsBulgarianNotTheWireValue() {
        let region = RegionAggregate(regionCode: "BG-16", listings: [
            listing("1", region: "BG-16", price: "200", currency: "EUR"),
        ])
        XCTAssertEqual(region.name, "Пловдив")
        XCTAssertNotEqual(region.name, "Plovdiv")
    }

    /// An unknown code falls back to the server's English name rather than
    /// rendering a bare code at an operator.
    func testAnUnknownCodeFallsBackToTheWireName() {
        XCTAssertEqual(BulgarianRegion.name(code: "BG-99", fallback: "Someplace"), "Someplace")
        XCTAssertEqual(BulgarianRegion.name(code: "BG-99"), "BG-99")
        XCTAssertEqual(BulgarianRegion.name(code: "bg-16"), "Пловдив", "lookup must fold case")
    }
}
