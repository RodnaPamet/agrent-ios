import Foundation

/// A field operation recorded with no signal, kept until it lands.
///
/// ── Why this can exist at all ──
///
/// Idempotency in this API is PER-USECASE, not global. `field-operation`
/// is one of the routes that honour `Idempotency-Key` (the table is in
/// ROADMAP.md, "Writes: the rule is per-usecase") — so replaying a queued
/// write with the SAME key cannot create a second operation, no matter how
/// many times it is retried or how long after the fact.
///
/// That is the whole licence for this file. The exchange listing create
/// honours no key and has no natural key, so a replay puts a second offer
/// on a public board: it must never be queued, and it is not.
///
/// An exchange MESSAGE is not queued either, although its send honours a
/// key and a replay would be safe on the server (#114). Safe is not the
/// question: a line of a negotiation arriving hours after it was typed, into
/// a conversation that moved on while the phone had no signal, is a
/// different message from the one the farmer wrote. The composer keeps the
/// draft and says it was not sent; sending it later is the farmer's call.
struct PendingOperation: Codable, Identifiable, Equatable, Sendable {
    /// THE IDEMPOTENCY KEY, and the file name, and the identity.
    ///
    /// One value doing all three is deliberate. A queue that minted a
    /// separate id would eventually let two rows carry the same key or one
    /// row carry two, and either of those is how a duplicate spray reaches
    /// a legally filed register.
    let id: String

    let locationID: String

    /// WHO queued it — the `/api/auth/me` id of the user signed in when it
    /// was recorded (agri-saas#1191 P0.9).
    ///
    /// ── Why it is needed ──
    ///
    /// A replay goes out under the CURRENT session's token, and the server
    /// attributes a field operation to whoever that is: `createFieldOperation`
    /// writes `ctx.userId` into the audit trail and `completedByUserId`, and
    /// its idempotency lookup is scoped to the TENANT, not the user — there is
    /// no server-side `queuedByUserId` check on this route to catch a
    /// mismatch (`queuedByUserId` lives in the WEB client's outbox, #786/#932).
    /// So on a shared phone, A's spray drained after B signs in would be filed
    /// as B's, permanently, on a БАБХ record. The only guard is this field and
    /// the drain's filter on it (`OutboxStore.belongs`).
    ///
    /// ── OPTIONAL, and it has to be ──
    ///
    /// Rows already on disk have no such key. A non-optional field — even
    /// with a default — throws `keyNotFound` on every one of them, and
    /// `all()`'s `try?` would then silently HIDE every queued spray: on disk,
    /// never sent, never shown (see `OutboxStore.pause`'s note, measured).
    /// Optional decodes a missing key as nil.
    ///
    /// ── nil means "from before this field existed" ──
    ///
    /// And it belongs to whoever is signed in next, who CLAIMS it (the drain
    /// stamps their id on it before anything else). That is what the build
    /// before this one would have done with it anyway, and in the case that
    /// produces such a row — an update installed over a queue — the next
    /// person signed in is overwhelmingly the person who queued it, since the
    /// old Изход did not clear the queue but nobody had a reason to sign out
    /// either. The web makes the same call for its unattributed rows in
    /// `flushOutbox`. Claiming, rather than leaving it unowned, means it
    /// cannot wander on to a THIRD account later.
    var ownerUserID: String? = nil

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
    /// A 429 stays in this list, and the operation sheet's «Запази за
    /// по-късно» depends on it. What changed is what the DRAIN does with one:
    /// it pauses the whole queue and spends no attempt — see `OutboxStore`.
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
        if case APIClient.APIError.http(let status, _, _, _, _) = error {
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

    /// Stamp `owner` on every row that has none — see
    /// `PendingOperation.ownerUserID` for why unowned rows are the next
    /// signed-in user's. Rows that already have an owner are never touched:
    /// re-stamping one is exactly how A's spray would become B's.
    func claimUnowned(for owner: String) {
        for var operation in all() where operation.ownerUserID == nil {
            operation.ownerUserID = owner
            enqueue(operation)
        }
    }

    private func fileURL(_ id: String) -> URL {
        // The id is a UUID string from `UUID().uuidString`, so it cannot
        // contain a path separator. Asserted by a test rather than assumed,
        // because a value that becomes a file name is a value that can
        // escape a directory.
        directory.appendingPathComponent(id, isDirectory: false)
    }
}
