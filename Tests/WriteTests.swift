import XCTest
@testable import Agrent

/// The three remaining writes, and the thing that differs between them is
/// NOT the HTTP — it is what a duplicate costs. This API has three
/// different idempotency stories and each one decides a different retry
/// policy:
///
///     invite    upserts on @@unique([tenantId, email])  → retry is safe
///     listing   no idempotency, no natural key          → never retry
///     deactivate  filters status ACTIVE, so a replay    → never retry,
///                 404s on a write that SUCCEEDED           re-read instead
final class ExchangeListingWriteTests: XCTestCase {

    private func draft(
        quantity: Decimal = 100, price: Decimal? = 200, region: String = "BG-PVN"
    ) -> CreateExchangeListing {
        CreateExchangeListing(
            side: "SELL", kind: "CULTURE", commodity: "wheat",
            quantityTonnes: quantity, pricePerTonne: price,
            regionCode: region, description: nil,
            sellerDisplayName: nil, sellerContact: nil, expiresAt: nil
        )
    }

    func testAValidDraftHasNoProblems() {
        XCTAssertTrue(draft().problems.isEmpty)
    }

    /// `0 < quantity ≤ 1_000_000`, mirrored from the server so an operator
    /// learns before a request that must not be attempted twice.
    func testQuantityBounds() {
        XCTAssertEqual(draft(quantity: 0).problems, [.quantityOutOfRange])
        XCTAssertEqual(draft(quantity: -1).problems, [.quantityOutOfRange])
        XCTAssertTrue(draft(quantity: CreateExchangeListing.maxQuantity).problems.isEmpty)
        XCTAssertEqual(
            draft(quantity: CreateExchangeListing.maxQuantity + 1).problems,
            [.quantityOutOfRange])
    }

    /// Price may be ZERO — unlike quantity, and unlike a cost amount.
    /// "I will take it away for nothing" is a real offer on a board.
    func testPriceMayBeZeroOrAbsent() {
        XCTAssertTrue(draft(price: 0).problems.isEmpty)
        XCTAssertTrue(draft(price: nil).problems.isEmpty)
        XCTAssertEqual(
            draft(price: CreateExchangeListing.maxPrice + 1).problems, [.priceOutOfRange])
    }

    func testRegionIsRequired() {
        XCTAssertEqual(draft(region: "").problems, [.regionMissing])
        XCTAssertEqual(draft(region: "   ").problems, [.regionMissing])
    }

    /// `priceCurrency` is a `z.literal('EUR')`, not an enum — the exchange
    /// is single-currency by design and BGN is a 400. There is no picker
    /// because there is no choice, and the encoded body must say so.
    func testCurrencyIsAlwaysEUR() throws {
        let json = try String(data: JSONEncoder().encode(draft()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"priceCurrency\":\"EUR\""), json)
        XCTAssertFalse(json.contains("BGN"), json)
    }

    /// Decimals go out as JSON NUMBERS. This route would accept strings
    /// too — `boundedDecimal` is a union — but a number is unambiguous,
    /// and `Decimal` encodes as one without passing through `Double`.
    func testDecimalsEncodeAsNumbers() throws {
        let json = try String(
            data: JSONEncoder().encode(draft(quantity: Decimal(string: "12.5")!)),
            encoding: .utf8)!
        XCTAssertTrue(json.contains("\"quantityTonnes\":12.5"), json)
        XCTAssertFalse(json.contains("\"quantityTonnes\":\""), json)
    }

    /// The picker is driven from the canonical ten, because `commodity`
    /// transforms through `normalizeCommodity` server-side and a miss is a
    /// 400. Every option must survive that, and every one must have a
    /// Bulgarian name — an English slug in a picker is the "wheat" defect
    /// with a tap target.
    func testEveryOfferableCommodityIsCanonicalAndNamed() {
        XCTAssertEqual(NewListingView.canonicalCommodities.count, 10)
        for slug in NewListingView.canonicalCommodities {
            XCTAssertNotNil(CommodityName.table[slug], "\(slug) is not in the canonical table")
            let shown = CommodityName.canonical(slug)!
            XCTAssertTrue(shown.unicodeScalars.contains { $0.value > 0x400 }, shown)
        }
    }

    /// The input commodities share the slug space and are NOT offerable —
    /// a farm does not post a tonnage of diesel on a grain board.
    func testInputCommoditiesAreNotOfferable() {
        for slug in ["diesel", "urea", "dap", "map", "ammonium-nitrate"] {
            XCTAssertFalse(NewListingView.canonicalCommodities.contains(slug), slug)
        }
    }
}

final class AdminWriteTests: XCTestCase {

    private func member(
        _ id: String, role: MembershipRole, status: MembershipStatus
    ) -> Membership {
        Membership(
            id: id, userId: "u-\(id)", role: role, status: status,
            user: .init(id: "u-\(id)", name: "Член \(id)", email: "\(id)@x.invalid", image: nil),
            invitedBy: nil, invitedAt: nil, deactivatedAt: nil,
            activeSessionCount: 0,
            createdAt: Date(), updatedAt: Date()
        )
    }

    /// The last active OWNER cannot be deactivated — refused server-side,
    /// counted live, with a database trigger behind it. Counted here too
    /// so the control is ABSENT rather than present and refused.
    @MainActor
    func testTheLastActiveOwnerIsProtected() async {
        let store = AdminStore()
        let owner = member("1", role: .owner, status: .active)
        store.setMembersForTesting([owner, member("2", role: .admin, status: .active)])
        XCTAssertTrue(store.isLastOwner(owner))
    }

    /// With two, neither is the last — the guard must not lock a farm out
    /// of managing itself.
    @MainActor
    func testTwoOwnersMeansNeitherIsLast() async {
        let store = AdminStore()
        let a = member("1", role: .owner, status: .active)
        let b = member("2", role: .owner, status: .active)
        store.setMembersForTesting([a, b])
        XCTAssertFalse(store.isLastOwner(a))
        XCTAssertFalse(store.isLastOwner(b))
    }

    /// A DEACTIVATED owner does not count toward the live total, so one
    /// active owner beside a deactivated one is still the last.
    @MainActor
    func testADeactivatedOwnerDoesNotCount() async {
        let store = AdminStore()
        let active = member("1", role: .owner, status: .active)
        store.setMembersForTesting([active, member("2", role: .owner, status: .deactivated)])
        XCTAssertTrue(store.isLastOwner(active))
    }

    /// The guard is about owners only — an admin is never the last
    /// anything.
    @MainActor
    func testNonOwnersAreNeverGuarded() async {
        let store = AdminStore()
        let admin = member("1", role: .admin, status: .active)
        store.setMembersForTesting([admin])
        XCTAssertFalse(store.isLastOwner(admin))
    }
}
