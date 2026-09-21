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
///  2. KEYED ON TENANT, NOT JUST PATH. `Config.tenantSlug` is hard-coded to
///     "agrent" today and will not always be. A cache keyed on path alone
///     serves one farm's journal to another the moment a tenant switcher
///     lands, and it would do it silently — the same shape as the database
///     mixup that bit this project last week.
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

    init(directoryName: String = "ResponseCache") {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Hashed so the filename carries neither the tenant nor the query in the
    /// clear. The NUL separator keeps `("ab", "c")` from colliding with
    /// `("a", "bc")`.
    static func key(tenant: String, pathAndQuery: String) -> String {
        let material = "\(tenant)\u{0}\(pathAndQuery)"
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
        } catch {
            // A cache that cannot write is a slow app, not a broken one.
            Log.cache.error("write failed: \(Log.summary(for: error), privacy: .public)")
        }
    }

    func remove(_ key: String) {
        try? fileManager.removeItem(at: fileURL(key))
        Log.cache.debug("evicted one entry")
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        Log.cache.debug("cleared")
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
    }
}
