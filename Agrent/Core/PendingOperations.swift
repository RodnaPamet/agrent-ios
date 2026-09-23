import Foundation

/// A field operation recorded with no signal, kept until it lands.
///
/// ── Why this can exist at all ──
///
/// Idempotency in this API is PER-USECASE, not global. `field-operation`
/// is one of the four that honours `Idempotency-Key` — so replaying a
/// queued write with the SAME key cannot create a second operation, no
/// matter how many times it is retried or how long after the fact.
///
/// That is the whole licence for this file. The exchange listing create
/// honours no key and has no natural key, so a replay puts a second offer
/// on a public board: it must never be queued, and it is not.
struct PendingOperation: Codable, Identifiable, Equatable, Sendable {
    /// THE IDEMPOTENCY KEY, and the file name, and the identity.
    ///
    /// One value doing all three is deliberate. A queue that minted a
    /// separate id would eventually let two rows carry the same key or one
    /// row carry two, and either of those is how a duplicate spray reaches
    /// a legally filed register.
    let id: String

    let locationID: String

    /// What to call it on screen. The parcel name and the kind of work —
    /// enough for a farmer to recognise which spray is waiting, without
    /// the outbox having to hold a second copy of the whole form.
    let parcelSummary: String
    let payload: Data
    let createdAt: Date

    var attempts: Int
    var lastAttemptAt: Date?
    var lastError: String?

    /// The server declined this one, and will decline it again.
    ///
    /// Distinguished from "not sent yet" because the two need opposite
    /// things from the farmer: one needs signal, the other needs a person
    /// to look at it. Showing both as "waiting to send" would leave a
    /// refused record waiting forever under a label that says it is fine.
    var isRefused: Bool = false
}

/// The outbox.
///
/// ── NOT in Caches ──
///
/// `ResponseCache` lives in Caches because it is reconstructible: iOS may
/// purge it under storage pressure and the app simply refetches. A spray
/// recorded in a field is not reconstructible by anything — the only copy
/// is the one the farmer typed — so purging it would silently destroy a
/// record of a regulated application. Application Support, which iOS does
/// not reclaim, and which is included in backups.
actor PendingOperations {
    static let shared = PendingOperations()

    private let directory: URL
    private let fileManager = FileManager.default

    init(directoryName: String = "PendingOperations") {
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask)[0]
        directory = support.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Should a failed write be kept and retried, or is it refused?
    ///
    /// Queueing a REFUSAL is worse than failing: it will never succeed, it
    /// sits in the outbox retrying forever, and the farmer is told their
    /// spray is "waiting to send" when the server has already declined it.
    ///
    /// So only failures that a later attempt could plausibly fix:
    ///   · any URLError — no signal, DNS, timeout, connection lost
    ///   · 5xx — the server is unwell, not disagreeing
    ///   · 408, 429 — explicitly "try again"
    ///
    /// Everything else is a decision the server has made. A 400 will be a
    /// 400 tomorrow; a 403 will be a 403.
    ///
    /// A DecodingError is NOT queued, and that is the subtle one: if the
    /// response failed to decode, the write very likely SUCCEEDED and only
    /// the reply was unreadable. Queueing it would be safe (the key
    /// dedupes) but it would show a farmer a pending row for work already
    /// done, which is a different lie from the one this prevents.
    nonisolated static func isWorthRetrying(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case APIClient.APIError.http(let status, _, _) = error {
            return status >= 500 || status == 408 || status == 429
        }
        return false
    }

    func enqueue(_ operation: PendingOperation) {
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                // Same protection as the cache: readable after the device
                // has been unlocked once, so a retry on launch works
                // without the farmer having to be looking at the screen.
                attributes: [.protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let data = try JSONEncoder().encode(operation)
            try data.write(to: fileURL(operation.id),
                           options: [.atomic,
                                     .completeFileProtectionUntilFirstUserAuthentication])
            Log.cache.info("queued operation for later")
        } catch {
            Log.cache.error("could not queue a pending operation")
        }
    }

    /// Oldest first — a queue of field records should drain in the order
    /// the work happened, not in whatever order the file system lists.
    func all() -> [PendingOperation] {
        guard let names = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return names
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(PendingOperation.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func count() -> Int { all().count }

    func remove(_ id: String) {
        try? fileManager.removeItem(at: fileURL(id))
    }

    func update(_ operation: PendingOperation) {
        enqueue(operation)
    }

    private func fileURL(_ id: String) -> URL {
        // The id is a UUID string from `UUID().uuidString`, so it cannot
        // contain a path separator. Asserted by a test rather than assumed,
        // because a value that becomes a file name is a value that can
        // escape a directory.
        directory.appendingPathComponent(id, isDirectory: false)
    }
}
