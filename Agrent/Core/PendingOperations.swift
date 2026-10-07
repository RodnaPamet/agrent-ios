import Foundation

/// Field work recorded with no signal, kept until it lands.
///
/// ── TWO KINDS, since agrent-ios#138 ──
///
///   - a field-operation CREATE (`POST /locations/{id}/operations`) — the
///     spray sheet's «Запази за по-късно». `lineMark` is nil.
///   - a parcel-line MARK (`PATCH /field-operations/{taskId}/parcels/
///     {lineId}`) — «Готово», «Пропусни» or «Отвори отново» on a task's line,
///     tapped with no signal. `lineMark` says which line, and the version the
///     operator SAW.
///
/// Each is safe to replay for its own reason, and the reasons differ:
///
/// ── Why the create can exist at all ──
///
/// Idempotency in this API is PER-USECASE, not global. `field-operation`
/// is one of the routes that honour `Idempotency-Key` (the table is in
/// ROADMAP.md, "Writes: the rule is per-usecase") — so replaying a queued
/// write with the SAME key cannot create a second operation, no matter how
/// many times it is retried or how long after the fact.
///
/// That is the whole licence for the create. The exchange listing create
/// honours no key and has no natural key, so a replay puts a second offer
/// on a public board: it must never be queued, and it is not.
///
/// ── Why the mark can ──
///
/// NOT idempotency: the PATCH reads no key. Its licence is the optimistic
/// lock. The mark replays with `If-Match: <the version it saw>`, so a
/// replay of the operator's own success comes back 200 `alreadyApplied`
/// (no second stock deduction, no second ДНЕВНИК row), and a replay over
/// SOMEONE ELSE's change comes back 409 instead of overwriting it — which
/// the drain parks as a `conflict` for the operator, never as refused and
/// never as sent (#138; the web does the same in `use-offline-sync.ts`).
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

    /// The location a CREATE posts under. nil for a line mark, whose path is
    /// the task and the line.
    ///
    /// Optional since #138, and only that: every row written before it has
    /// the key, and an Optional decodes a PRESENT key exactly as the
    /// non-optional did — so old rows read unchanged. What it gave up is the
    /// compiler's word that a create has one; `target` takes that back by
    /// refusing to name a destination for a row that has neither.
    let locationID: String?

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

    /// Present on a parcel-line MARK, absent on a create (#138).
    ///
    /// OPTIONAL, for the reason `ownerUserID` gives: a non-optional field,
    /// even with a default, throws `keyNotFound` on every row already on
    /// disk, and `all()`'s `try?` would then hide every queued spray. Its
    /// ABSENCE is what says "a create", so the rows from before #138 — all
    /// creates — say so without being rewritten.
    var lineMark: LineMark? = nil

    /// The server answered this mark's replay 409 STALE_DATA: the line moved
    /// on while the mark sat on the phone (#138).
    ///
    /// NOT `isRefused`. A refusal is the server disagreeing with the work; a
    /// conflict is somebody else's change arriving first, and the only person
    /// who can say which one should stand is the operator. So it is held
    /// apart — never re-sent by the drain, never counted as waiting, never
    /// shown as refused — until they choose «Запази моята» (re-send at the
    /// server's version, deliberately) or «Използвай сървъра» (discard
    /// theirs). Optional, for the same on-disk reason as `lineMark`.
    var conflict: Conflict? = nil

    /// Which line a queued mark sets, and the version it was SEEN at.
    struct LineMark: Codable, Equatable, Sendable {
        let taskID: String
        let lineID: String

        /// The wire value the mark sets — `DONE`, `SKIPPED` or `PENDING` —
        /// so a screen can show the queued state without parsing `payload`.
        /// The PAYLOAD is what is sent; this only names it. A string rather
        /// than `OperationLineStatus`, so a value this build cannot name is
        /// still a row the queue can read.
        let status: String

        /// THE If-Match OF EVERY REPLAY: the line's version when the operator
        /// looked at it, never bumped on the phone.
        ///
        /// Not bumped even when a second tap on the same line replaces this
        /// one (`OutboxStore.enqueueMark`): at most one unsent mark exists per
        /// line, and it must assert the version the SERVER is known to hold.
        /// Bumping would guarantee the 409 the replacement exists to avoid —
        /// the web learned that in #934. `var` for one writer only:
        /// «Запази моята» moves it to the server's current version, which is
        /// the operator choosing to overwrite.
        var seenVersion: Int

        var lineStatus: OperationLineStatus {
            OperationLineStatus(rawValue: status) ?? .unknown
        }
    }

    /// What the 409 said, kept for the operator's decision.
    struct Conflict: Codable, Equatable, Sendable {
        /// The line's version on the server when it refused — `error.details
        /// .currentVersion`, never the body root (#922 on the web). It is what
        /// «Запази моята» re-sends with. nil when the server could not say, and
        /// then «Запази моята» is not offered: re-sending without a version
        /// would be the unguarded overwrite, and re-sending with the old one
        /// would only meet the same 409.
        let currentVersion: Int?
        let at: Date

        init(currentVersion: Int?, at: Date) {
            self.currentVersion = currentVersion
            self.at = at
        }

        /// A 409 on a MARK's replay, and nothing else.
        ///
        /// A create that meets 409 stays what it always was — refused — since
        /// its route has no lock and there is nothing to choose between. Pure,
        /// because it is the whole rule the drain applies.
        init?(replayOf item: PendingOperation, failedWith error: Error, at now: Date = Date()) {
            guard item.lineMark != nil,
                  case APIClient.APIError.conflict(let current, _) = error else { return nil }
            currentVersion = current
            at = now
        }
    }

    /// Where a replay goes, for the two kinds.
    enum Target: Equatable, Sendable {
        case create(locationID: String)
        case mark(LineMark)
    }

    /// nil only for a row with neither — which nothing in this app writes,
    /// and which the drain then refuses rather than guessing a route for.
    var target: Target? {
        if let lineMark { return .mark(lineMark) }
        if let locationID { return .create(locationID: locationID) }
        return nil
    }

    /// Should the drain send it? Not when refused, and not while a conflict
    /// waits for a person.
    var awaitsSend: Bool { !isRefused && conflict == nil }

    /// A mark for the outbox, built the one way the app builds one.
    ///
    /// The id is a fresh UUID — the file name and the identity, as for a
    /// create; the route reads no key, so it is nothing more.
    static func mark(
        id: String = UUID().uuidString,
        _ mark: LineMark,
        ownerUserID: String,
        summary: String,
        payload: Data,
        reason: String?,
        at now: Date = Date()
    ) -> PendingOperation {
        PendingOperation(
            id: id, locationID: nil, ownerUserID: ownerUserID,
            parcelSummary: summary, payload: payload, createdAt: now,
            attempts: 0, lastAttemptAt: nil, lastError: reason,
            lineMark: mark
        )
    }
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
    /// A 409 is not queued either, and on a parcel-line mark it is not a
    /// refusal: it is a conflict, which the task screen states and reloads
    /// when it meets one live, and the drain parks for the operator when a
    /// replay meets one (`PendingOperation.Conflict`, #138).
    ///
    /// A 426 (`APIError.clientTooOld`) is not worth retrying either, and it
    /// is not a refusal of anything: the server's version gate turned the
    /// BUILD away before any route ran, and retrying from the same build buys
    /// the same answer. Whatever must not read it as final checks for it
    /// FIRST: the drain stops on it and touches nothing (`OutboxStore`, #168),
    /// a parcel line's tap leaves the queue alone (`FieldOperationRules
    /// .failure`), and the spray sheet offers «Запази за по-късно» on one all
    /// the same — kept for the updated app, where the web's live path keeps
    /// nothing (`ParcelOperationSheet.QueueOffer`, #169).
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

    /// Rewrite a row ONLY if it is still on disk — and say whether it was.
    ///
    /// The drain's write-back after a failed send, since #138 gave the queue
    /// a way to lose a row other than delivering it: a second tap on a line
    /// REPLACES the unsent mark for it (`OutboxStore.enqueueMark`), and
    /// «Използвай сървъра» discards a conflict. Either can land while the
    /// drain is awaiting that very row's send. A plain `update` would then
    /// write the row back — resurrecting a mark the operator had replaced,
    /// to replay over their newer one. The check and the write share one
    /// actor turn, so nothing can remove the file between them.
    @discardableResult
    func updateIfPresent(_ operation: PendingOperation) -> Bool {
        guard fileManager.fileExists(atPath: fileURL(operation.id).path) else { return false }
        enqueue(operation)
        return true
    }

    /// One row as it is on disk NOW, or nil if it is gone or unreadable.
    ///
    /// For the drain, which walks a list read when its pass began: a row
    /// replaced or parked since then must be seen as it is, not as it was.
    func row(_ id: String) -> PendingOperation? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? JSONDecoder().decode(PendingOperation.self, from: data)
    }

    /// «Запази моята», decided against the row on DISK in one actor turn:
    /// only a row that is STILL `owner`'s parked conflict, with a version to
    /// re-send at, is re-queued at that version. Returns whether it was.
    ///
    /// Not built from the screen's copy of the row. That copy can be a step
    /// behind — a second tap on the button, or a resolution that landed in
    /// between — and writing it back would overwrite whatever the row has
    /// become since.
    func requeueConflict(_ id: String, owner: String?) -> Bool {
        guard var item = row(id), OutboxStore.belongs(item, to: owner),
              let current = item.conflict?.currentVersion,
              var mark = item.lineMark else { return false }
        mark.seenVersion = current
        item.lineMark = mark
        item.conflict = nil
        enqueue(item)
        return true
    }

    /// «Използвай сървъра», on the same terms: only `owner`'s row that is
    /// still a parked conflict is discarded. Never a row that could be sent.
    func discardConflict(_ id: String, owner: String?) -> Bool {
        guard let item = row(id), OutboxStore.belongs(item, to: owner),
              item.conflict != nil else { return false }
        remove(id)
        return true
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
