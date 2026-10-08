import CryptoKit
import Foundation

/// Last-known-good response bodies on disk, so a screen opened with no signal
/// shows something rather than an apology.
///
/// FOUR DECISIONS WORTH THE WORDS, because each has a wrong answer that looks
/// reasonable:
///
///  1. RAW `Data`, NOT DECODED MODELS. Decoding happens on read, so a change
///     to `LogEntry` cannot corrupt the cache format — the worst case is one
///     entry failing to decode, which is recoverable by discarding it. Storing
///     decoded models would also need a separate cache per type, where this is
///     one cache for every endpoint the app will ever add.
///
///  2. KEYED ON USER AND TENANT, NOT JUST PATH (`CacheScope`). The open farm
///     changes (agrent-ios#179), and a cache keyed on path alone would serve
///     one farm's journal to another; with NO farm open there is no key and
///     no cache (#192). And the USER is in the key because a farm phone is
///     shared: until agri-saas#1191 P0.9 this survived sign-out keyed on the
///     tenant alone, so account B signing in on A's phone was served A's
///     cached journal, members and farm profile whenever the network was
///     slower than the cache. The purge on sign-out (`SessionReset`) is the
///     first line; the key is the one that holds when the purge does not run
///     — a crash mid-sign-out, a refresh 401 that clears the tokens without
///     Изход, an `OfflinePrefetch` write that lands after the purge.
///
///  3. THE QUERY IS PART OF THE KEY. `?limit=50` and `?limit=200` are
///     different resources, and a cache that ignores the query answers one
///     with the other. This is the one place the query string is NOT dropped;
///     it is hashed into the filename, so it never lands on disk in the clear
///     and never reaches the log.
///
///  4. FILE PROTECTION MATCHES THE KEYCHAIN, NOT THE DEFAULT. `TokenStore`
///     chose `kSecAttrAccessibleAfterFirstUnlock` deliberately, so a farm
///     phone in a pocket keeps working in the background. This cache holds the
///     same tenant's data and gets the file equivalent,
///     `.completeUntilFirstUserAuthentication` — matching, not laxer. Caches
///     directory rather than Documents: this is reconstructible, so it should
///     not be backed up or counted against the user's iCloud quota.
actor ResponseCache {
    static let shared = ResponseCache()

    private let directory: URL
    private let fileManager = FileManager.default
    private let byteBudget: Int

    /// 8 MB. Chosen against measured payloads rather than picked round: the
    /// journal is 10 KB, the calculator 0.6 KB, and one location's parcels are
    /// 22 KB. A farm with fifty fields caching every parcel set still sits
    /// near 1 MB, so the budget is roughly an order of magnitude of headroom
    /// over the largest realistic working set.
    static let defaultByteBudget = 8 * 1024 * 1024

    init(directoryName: String = "ResponseCache", byteBudget: Int = ResponseCache.defaultByteBudget) {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent(directoryName, isDirectory: true)
        self.byteBudget = byteBudget
    }

    /// Hashed so the filename carries neither the user, the tenant nor the
    /// query in the clear. The NUL separators keep `("ab", "c")` from
    /// colliding with `("a", "bc")`.
    ///
    /// The ONLY key function, and it takes a `CacheScope` — a value that
    /// cannot be built without a user id. The tenant-only `key(tenant:…)` it
    /// replaced is deleted rather than deprecated, so "cache something
    /// without saying whose it is" is a compile error, not a review comment.
    /// Entries written under the old keys are unreachable from here and age
    /// out under the byte budget; the first Изход removes them outright.
    static func key(scope: CacheScope, pathAndQuery: String) -> String {
        let material = "\(scope.userID)\u{0}\(scope.tenant)\u{0}\(pathAndQuery)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `fetchedAt` is the file's modification date, so the age shown on screen
    /// is the age of the bytes rather than a timestamp we remembered to write.
    func read(_ key: String) -> (data: Data, fetchedAt: Date)? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fetchedAt = attributes[.modificationDate] as? Date
        else {
            Log.cache.debug("miss")
            return nil
        }
        Log.cache.debug("hit \(data.count, privacy: .public)B")
        return (data, fetchedAt)
    }

    func write(_ key: String, _ data: Data) {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try data.write(
                to: fileURL(key),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            Log.cache.debug("wrote \(data.count, privacy: .public)B")
            evictIfOverBudget(keeping: key)
        } catch {
            // A cache that cannot write is a slow app, not a broken one.
            Log.cache.error("write failed: \(Log.summary(for: error), privacy: .public)")
        }
    }

    func remove(_ key: String) {
        try? fileManager.removeItem(at: fileURL(key))
        Log.cache.debug("evicted one entry")
    }

    /// Everything, every user's. Called by `SessionReset` on Изход and on
    /// every sign-in.
    ///
    /// All of it rather than the departing user's entries alone: at the
    /// moment of a sign-out the only scope that SHOULD have entries is the
    /// departing one, so anything else on disk is an orphan of a purge that
    /// did not run — and the fix for a missed purge is a purge, not a filter
    /// that preserves it. The cost is that A, signing back in, starts cold.
    func removeAll() {
        try? fileManager.removeItem(at: directory)
        Log.cache.debug("cleared")
    }

    /// Keep the cache under its byte budget, oldest first.
    ///
    /// Before this, the cache was UNBOUNDED: no cap, no entry limit, and the
    /// only eviction was iOS purging the whole Caches directory at a moment of
    /// its choosing — which, for a farm app, can be immediately before someone
    /// walks into a field with no signal. Losing the oldest entry to stay
    /// under a budget we chose is strictly better than losing everything at a
    /// time the system chose.
    ///
    /// Ordered by modification date, which here means LAST SUCCESSFUL FETCH:
    /// entries are rewritten on every refresh, so the oldest file is the least
    /// recently confirmed. Reads deliberately do not touch it — promoting on
    /// read would keep a screen nobody refreshes ahead of one that is actively
    /// failing over to cache.
    ///
    /// The entry just written is never the one evicted, however tight the
    /// budget: writing and immediately discarding would be worse than not
    /// caching at all.
    private func evictIfOverBudget(keeping key: String) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var sized: [(url: URL, size: Int, modified: Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, size, modified)
        }

        var total = sized.reduce(0) { $0 + $1.size }
        guard total > byteBudget else { return }

        sized.sort { $0.modified < $1.modified }
        for entry in sized where total > byteBudget {
            guard entry.url.lastPathComponent != key else { continue }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            Log.cache.debug("evicted \(entry.size, privacy: .public)B over budget")
        }
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
    }
}

/// Whose cache entry this is: the signed-in user and the farm.
///
/// Built only by `current()` in the app, which returns nil when nobody's
/// identity is known — and nil means NO CACHE, not a shared one. See
/// `SessionIdentity` for why unknown fails closed.
struct CacheScope: Equatable, Sendable {
    let userID: String
    let tenant: String

    static func current(identity: SessionIdentity = .shared) -> CacheScope? {
        // No farm open, no cache: an entry needs a farm to belong to, and
        // keying one under the pinned farm is the guess `FarmPath` stopped.
        guard let userID = identity.userID, let farm = FarmPath.openSlug else { return nil }
        return CacheScope(userID: userID, tenant: farm)
    }
}
