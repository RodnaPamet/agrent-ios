import XCTest
@testable import Agrent

/// The cache was UNBOUNDED until hardening: no size cap, no entry limit, and
/// the only eviction was iOS purging the whole Caches directory at a moment of
/// its choosing — which for a farm app can be immediately before someone walks
/// into a field with no signal.
final class ResponseCacheTests: XCTestCase {

    /// A fresh directory per test so runs cannot contaminate each other.
    private func makeCache(budget: Int) -> (ResponseCache, String) {
        let name = "ResponseCacheTests-\(UUID().uuidString)"
        return (ResponseCache(directoryName: name, byteBudget: budget), name)
    }

    private func payload(_ bytes: Int) -> Data { Data(repeating: 0x41, count: bytes) }

    func testWritesAndReadsBack() async {
        let (cache, _) = makeCache(budget: 10_000)
        await cache.write("a", payload(100))
        let hit = await cache.read("a")
        XCTAssertEqual(hit?.data.count, 100)
        await cache.removeAll()
    }

    func testMissReturnsNil() async {
        let (cache, _) = makeCache(budget: 10_000)
        let hit = await cache.read("absent")
        XCTAssertNil(hit)
        await cache.removeAll()
    }

    /// Oldest-first eviction, where "oldest" is the least recently FETCHED —
    /// entries are rewritten on every refresh, so modification date tracks
    /// last confirmation.
    func testEvictsOldestOnceOverBudget() async {
        let (cache, _) = makeCache(budget: 2_500)

        await cache.write("first", payload(1_000))
        await cache.write("second", payload(1_000))
        // Still under budget: both survive.
        var first = await cache.read("first")
        XCTAssertNotNil(first)

        // Tips it over — the oldest must go.
        await cache.write("third", payload(1_000))

        first = await cache.read("first")
        let second = await cache.read("second")
        let third = await cache.read("third")
        XCTAssertNil(first, "oldest entry should have been evicted")
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
        await cache.removeAll()
    }

    /// Writing something and immediately discarding it would be worse than not
    /// caching at all, so the entry just written is never the eviction victim
    /// however tight the budget.
    func testNeverEvictsTheEntryJustWritten() async {
        let (cache, _) = makeCache(budget: 100)
        await cache.write("only", payload(5_000))
        let hit = await cache.read("only")
        XCTAssertNotNil(hit, "the just-written entry must survive its own eviction pass")
        XCTAssertEqual(hit?.data.count, 5_000)
        await cache.removeAll()
    }

    func testRemoveDropsOneEntryAndLeavesOthers() async {
        let (cache, _) = makeCache(budget: 10_000)
        await cache.write("a", payload(10))
        await cache.write("b", payload(10))
        await cache.remove("a")
        let a = await cache.read("a")
        let b = await cache.read("b")
        XCTAssertNil(a)
        XCTAssertNotNil(b)
        await cache.removeAll()
    }

    /// Keys are hashed, so neither the tenant nor the query reaches the disk
    /// in the clear — and two tenants cannot collide on one path.
    func testKeyIsHashedAndTenantScoped() {
        let a = ResponseCache.key(tenant: "agrent", pathAndQuery: "/api/t/agrent/journal?limit=50")
        let b = ResponseCache.key(tenant: "other", pathAndQuery: "/api/t/agrent/journal?limit=50")
        let c = ResponseCache.key(tenant: "agrent", pathAndQuery: "/api/t/agrent/journal?limit=10")

        XCTAssertNotEqual(a, b, "different tenants must not share a cache entry")
        XCTAssertNotEqual(a, c, "different queries are different resources")
        XCTAssertFalse(a.contains("agrent"))
        XCTAssertFalse(a.contains("limit"))
        XCTAssertEqual(a.count, 64, "SHA256 hex")
    }

    /// The NUL separator stops ("ab","c") colliding with ("a","bc").
    func testKeySeparatorPreventsConcatenationCollisions() {
        XCTAssertNotEqual(
            ResponseCache.key(tenant: "ab", pathAndQuery: "c"),
            ResponseCache.key(tenant: "a", pathAndQuery: "bc")
        )
    }
}
