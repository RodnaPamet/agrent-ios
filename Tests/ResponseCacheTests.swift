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

    /// Keys are hashed, so neither the user, the tenant nor the query reaches
    /// the disk in the clear — and two tenants or two USERS cannot collide on
    /// one path (agri-saas#1191 P0.9: a shared phone is the ordinary case).
    func testKeyIsHashedAndScopedToUserAndTenant() {
        let path = "/api/t/agrent/journal?limit=50"
        let a = ResponseCache.key(scope: CacheScope(userID: "user-a", tenant: "agrent"), pathAndQuery: path)
        let b = ResponseCache.key(scope: CacheScope(userID: "user-a", tenant: "other"), pathAndQuery: path)
        let c = ResponseCache.key(scope: CacheScope(userID: "user-a", tenant: "agrent"),
                                  pathAndQuery: "/api/t/agrent/journal?limit=10")
        let d = ResponseCache.key(scope: CacheScope(userID: "user-b", tenant: "agrent"), pathAndQuery: path)

        XCTAssertNotEqual(a, b, "different tenants must not share a cache entry")
        XCTAssertNotEqual(a, c, "different queries are different resources")
        XCTAssertNotEqual(a, d, "different users on one farm must not share a cache entry")
        XCTAssertFalse(a.contains("agrent"))
        XCTAssertFalse(a.contains("user-a"))
        XCTAssertFalse(a.contains("limit"))
        XCTAssertEqual(a.count, 64, "SHA256 hex")
    }

    /// The NUL separators stop ("ab","c") colliding with ("a","bc") — in
    /// either boundary.
    func testKeySeparatorPreventsConcatenationCollisions() {
        XCTAssertNotEqual(
            ResponseCache.key(scope: CacheScope(userID: "u", tenant: "ab"), pathAndQuery: "c"),
            ResponseCache.key(scope: CacheScope(userID: "u", tenant: "a"), pathAndQuery: "bc")
        )
        XCTAssertNotEqual(
            ResponseCache.key(scope: CacheScope(userID: "ab", tenant: "c"), pathAndQuery: "p"),
            ResponseCache.key(scope: CacheScope(userID: "a", tenant: "bc"), pathAndQuery: "p")
        )
    }

    // MARK: - The ETag (agrent-ios#329)

    /// A body keeps the ETag it came with, readable without the body.
    func testAnEntryKeepsItsETag() async {
        let (cache, _) = makeCache(budget: 10_000)
        await cache.write("a", payload(10), etag: #"W/"abc123""#)
        let tag = await cache.etag("a")
        XCTAssertEqual(tag, #"W/"abc123""#)
        let hit = await cache.read("a")
        XCTAssertEqual(hit?.etag, #"W/"abc123""#)
        await cache.removeAll()
    }

    /// A new body without an ETag must not inherit the old one: that tag
    /// would earn a 304 for bytes the server never sent.
    func testABodyWithoutAnETagClearsTheOldOne() async {
        let (cache, _) = makeCache(budget: 10_000)
        await cache.write("a", payload(10), etag: #""v1""#)
        await cache.write("a", payload(20))
        let tag = await cache.etag("a")
        XCTAssertNil(tag)
        await cache.write("a", payload(30), etag: #""v3""#)
        let replaced = await cache.etag("a")
        XCTAssertEqual(replaced, #""v3""#)
        await cache.removeAll()
    }

    /// Removing the entry takes its tag with it; a miss has none, and an
    /// entry written before ETags existed has none either.
    func testNoEntryNoETag() async {
        let (cache, _) = makeCache(budget: 10_000)
        await cache.write("a", payload(10), etag: #""v1""#)
        await cache.remove("a")
        let removed = await cache.etag("a")
        XCTAssertNil(removed)
        let absent = await cache.etag("never")
        XCTAssertNil(absent)
        await cache.write("old", payload(10))
        let old = await cache.read("old")
        XCTAssertNotNil(old)
        XCTAssertNil(old?.etag)
        await cache.removeAll()
    }

    /// A 304 restarts the entry's age, and changes nothing else.
    func testAConfirmationRestartsTheAge() async throws {
        let (cache, _) = makeCache(budget: 10_000)
        await cache.write("a", payload(10), etag: #""v1""#)
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        await cache.confirm("a", at: then)
        let before = await cache.read("a")
        XCTAssertEqual(try XCTUnwrap(before?.fetchedAt).timeIntervalSince1970, then.timeIntervalSince1970, accuracy: 1)
        let now = Date()
        await cache.confirm("a", at: now)
        let after = await cache.read("a")
        XCTAssertEqual(try XCTUnwrap(after?.fetchedAt).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(after?.data.count, 10)
        XCTAssertEqual(after?.etag, #""v1""#)
        await cache.removeAll()
    }

    /// The request side, read from the source: there is no URLProtocol seam
    /// in `Tests/`. The cache's entry tag goes out as `If-None-Match`, the
    /// response's tag is stored with its body, and a 304 the entry can't
    /// answer asks again without one.
    func testTheCacheRevalidatesWithItsETag() throws {
        func source(_ path: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let resource = try source("Agrent/Core/CachedResource.swift")
        XCTAssertTrue(resource.contains("enum CachedResource"), "positive control")
        XCTAssertTrue(resource.contains("ResponseCache.shared.etag(key)"))
        XCTAssertTrue(resource.contains("conditionalData(for: pathAndQuery, ifNoneMatch: tag)"))
        XCTAssertTrue(resource.contains("write(key, data, etag: etag)"))
        XCTAssertTrue(resource.contains("load(pathAndQuery, conditional: false, decode: decode)"))
        let client = try source("Agrent/API/APIClient.swift")
        XCTAssertTrue(client.contains(#"forHTTPHeaderField: "If-None-Match")"#))
        XCTAssertTrue(client.contains(#"http.value(forHTTPHeaderField: "ETag")"#))
    }
}
