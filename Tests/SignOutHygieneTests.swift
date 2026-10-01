import XCTest
@testable import Agrent

/// agri-saas#1191 P0.9 — the plan's test, verbatim: account B signing in on
/// the same phone after A signs out sees NOTHING of account A.
///
/// ── What runs for real, and what is a seam ──
///
/// The singletons are the REAL `shared` instances, reset by the real
/// `SessionReset.resetUserState()`. Three things are seams, because this
/// suite runs inside the app on whatever simulator it is pointed at — which
/// may be the owner's signed-in one — and must leave it as it found it:
///
///   · the Keychain: `clearTokens` is a no-op and the identity is a
///     `SessionIdentity` over a variable, not over `TokenStore`;
///   · the response cache: a `ResponseCache` in a directory of its own;
///   · the outbox: an `OutboxStore` over its own `PendingOperations`
///     directory, whose sender records instead of POSTing.
///
/// Where nothing can be observed at runtime — the order of lines in
/// `signOut`, a guard on a request in flight — the checks read the source,
/// each with a positive control so a moved file fails rather than passes.
@MainActor
final class SignOutHygieneTests: XCTestCase {

    // MARK: - fixtures

    private let userA = "user-a-0001"
    private let userB = "user-b-0002"

    /// A `SessionIdentity` whose "Keychain" is this variable.
    private final class FakeKeychain { var owner: String? }

    private func makeIdentity(_ keychain: FakeKeychain) -> SessionIdentity {
        SessionIdentity(load: { keychain.owner }, save: { keychain.owner = $0 })
    }

    private func makeCache() -> ResponseCache {
        ResponseCache(directoryName: "SignOutHygiene-\(UUID().uuidString)")
    }

    /// Records what the drain sends; never touches the network.
    private final class Sent { var ids: [String] = [] }

    private func makeOutbox(identity: SessionIdentity, sent: Sent)
        -> (OutboxStore, PendingOperations) {
        let queue = PendingOperations(directoryName: "SignOutHygiene-\(UUID().uuidString)")
        let store = OutboxStore(
            queue: queue,
            currentOwner: { identity.userID },
            identify: {},
            send: { sent.ids.append($0.id) }
        )
        return (store, queue)
    }

    /// Strictly increasing `createdAt`, so "oldest first" is the order the
    /// test made them in rather than whatever two equal dates sort to.
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func operation(owner: String?, summary: String) -> PendingOperation {
        clock.addTimeInterval(1)
        return PendingOperation(
            id: UUID().uuidString, locationID: "loc", ownerUserID: owner,
            parcelSummary: summary,
            payload: Data(#"{"operationType":"SPRAY"}"#.utf8),
            createdAt: clock, attempts: 0, lastAttemptAt: nil, lastError: nil)
    }

    private func thread(_ id: String) -> ExchangeThreadSummary {
        ExchangeThreadSummary(id: id, listingId: "l", commodity: "wheat", listingRegionName: nil,
                              listingQuantityTonnes: nil, sellerDisplayName: nil, role: .seller,
                              lastMessageAt: Date(timeIntervalSince1970: 0), closed: false,
                              hasUnread: true)
    }

    private let tooMany = APIClient.APIError.http(
        status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: 60)

    /// The device's real dashboard arrangement, put back after the test that
    /// has to exercise the real `DashboardPreferences.shared`.
    private let dashboardKeys = ["dashboard.blocks", "dashboard.priceCommodity"]
    private var savedDashboard: [String: Any] = [:]

    override func setUp() async throws {
        for key in dashboardKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDashboard[key] = value }
        }
    }

    override func tearDown() async throws {
        for key in dashboardKeys {
            if let value = savedDashboard[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // Leave the singletons as a fresh launch would have them.
        SessionReset.resetUserState()
    }

    // MARK: - the plan's test

    func testAccountBOnTheSamePhoneSeesNothingOfAccountA() async throws {
        let keychain = FakeKeychain()
        let identity = makeIdentity(keychain)
        let cache = makeCache()
        let sent = Sent()
        let (outbox, queue) = makeOutbox(identity: identity, sent: sent)
        let paths = [MeAPI.path, "/api/t/agrent/journal?limit=50", "/api/t/agrent/admin/members"]

        // ── A is signed in, and leaves a trace in every store ──
        identity.adopt(userA)
        let scopeA = try XCTUnwrap(CacheScope.current(identity: identity))
        for path in paths {
            await cache.write(ResponseCache.key(scope: scopeA, pathAndQuery: path), Data("A's \(path)".utf8))
        }
        let sprayA = operation(owner: userA, summary: "A · Пръскане")
        let fertA = operation(owner: userA, summary: "A · Торене")
        await outbox.enqueue(sprayA)
        await outbox.enqueue(fertA)
        // The live save fails offline; this one is retried, not refused.
        CurrentUserStore.shared.adoptForTesting(
            CurrentUser(id: userA, name: "А", email: "a@example.invalid", role: "MECHANISATOR",
                        bottomTabOrder: ["/tasks"]))
        BottomTabsStore.shared.adopt(["/tasks", "/locations"], isOperator: true)
        ExchangeUnreadStore.shared.apply([thread("t1"), thread("t2")], asOf: SessionEpoch.current)
        RateLimitPause.messages.absorb(tooMany)
        OutboxStore.shared.pause.absorb(tooMany)
        DashboardPreferences.shared.select(.sunflower)
        if !DashboardPreferences.shared.isOn(.tasks) { DashboardPreferences.shared.toggle(.tasks) }

        // Positive controls: A really is visible everywhere before Изход, so
        // the emptiness below is the reset's doing and not the fixture's.
        XCTAssertEqual(outbox.pending.map(\.id), [sprayA.id, fertA.id])
        XCTAssertNotNil(CurrentUserStore.shared.user)
        XCTAssertEqual(BottomTabsStore.shared.storedForTesting, ["/tasks", "/locations"])
        XCTAssertEqual(ExchangeUnreadStore.shared.count, 2)
        XCTAssertTrue(RateLimitPause.messages.isPaused)
        XCTAssertTrue(OutboxStore.shared.pause.isPaused)
        XCTAssertEqual(DashboardPreferences.shared.priceCommodity, .sunflower)
        for path in paths {
            let hit = await cache.read(ResponseCache.key(scope: scopeA, pathAndQuery: path))
            XCTAssertNotNil(hit, "positive control: A's \(path) is cached")
        }

        // ── A signs out ──
        let epochBefore = SessionEpoch.current
        await SessionReset.endSession(clearTokens: {}, identity: identity, cache: cache).value
        // The test outbox stands in for `OutboxStore.shared`, which
        // `resetUserState` reset; give it the same treatment.
        outbox.reset()

        XCTAssertNotEqual(SessionEpoch.current, epochBefore, "in-flight work from A is not invalidated")
        XCTAssertNil(identity.userID)
        XCTAssertNil(keychain.owner, "the identity outlived the session on disk")
        XCTAssertNil(CacheScope.current(identity: identity), "a cache scope with nobody signed in")
        XCTAssertNil(CurrentUserStore.shared.user)
        XCTAssertNil(BottomTabsStore.shared.storedForTesting, "A's bar order survived")
        XCTAssertFalse(BottomTabsStore.shared.isOperator, "A's role survived")
        XCTAssertEqual(ExchangeUnreadStore.shared.count, 0, "A's unread badge survived")
        XCTAssertFalse(RateLimitPause.messages.isPaused, "A's farm's message pause survived")
        XCTAssertFalse(OutboxStore.shared.pause.isPaused)
        XCTAssertTrue(OutboxStore.shared.pending.isEmpty)
        XCTAssertEqual(DashboardPreferences.shared.blocks, DashboardBlock.defaultOrder)
        XCTAssertEqual(DashboardPreferences.shared.priceCommodity, .wheat)
        for key in dashboardKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) survived")
        }
        XCTAssertTrue(outbox.pending.isEmpty)
        for path in paths {
            let hit = await cache.read(ResponseCache.key(scope: scopeA, pathAndQuery: path))
            XCTAssertNil(hit, "A's \(path) survived the purge")
        }
        // PARKED, NOT DROPPED: A's work is still on disk, still A's.
        let parked = await queue.all()
        XCTAssertEqual(parked.map(\.id), [sprayA.id, fertA.id])
        XCTAssertEqual(Set(parked.compactMap(\.ownerUserID)), [userA])

        // ── B signs in ──
        identity.adopt(userB)
        let scopeB = try XCTUnwrap(CacheScope.current(identity: identity))
        // Even a purge that FAILED cannot serve A to B: put A's bytes back,
        // as a crash mid-sign-out would have left them, and look as B.
        for path in paths {
            await cache.write(ResponseCache.key(scope: scopeA, pathAndQuery: path), Data("A".utf8))
            let asB = await cache.read(ResponseCache.key(scope: scopeB, pathAndQuery: path))
            XCTAssertNil(asB, "B was served A's cached \(path)")
        }

        await outbox.refresh()
        XCTAssertTrue(outbox.pending.isEmpty, "B's banner shows A's queued work")
        await outbox.flush()
        XCTAssertTrue(sent.ids.isEmpty, "A's queued work was sent under B's session")

        let sprayB = operation(owner: userB, summary: "B · Пръскане")
        await outbox.enqueue(sprayB)
        XCTAssertEqual(outbox.pending.map(\.id), [sprayB.id], "B sees exactly B's own work")
        await outbox.flush()
        XCTAssertEqual(sent.ids, [sprayB.id], "B's own work did not go, or A's went with it")
        let onDisk = await queue.all()
        XCTAssertEqual(onDisk.map(\.id), [sprayA.id, fertA.id], "A's parked work was destroyed")

        // ── A signs back in: the parked work resumes ──
        await SessionReset.endSession(clearTokens: {}, identity: identity, cache: cache).value
        outbox.reset()
        identity.adopt(userA)
        await outbox.refresh()
        XCTAssertEqual(outbox.pending.map(\.id), [sprayA.id, fertA.id], "A's work did not come back")
        await outbox.flush()
        XCTAssertEqual(sent.ids, [sprayB.id, sprayA.id, fertA.id], "A's work did not resume, in order")
        let drained = await queue.all()
        XCTAssertTrue(drained.isEmpty)

        await cache.removeAll()
    }

    // MARK: - the outbox's ownership rule

    /// Pure, and the whole rule. Unknown fails CLOSED — the web's
    /// `flushOutbox` sent everything when the owner was null (#1005).
    func testOwnershipFailsClosed() {
        let a = operation(owner: userA, summary: "a")
        let legacy = operation(owner: nil, summary: "legacy")
        XCTAssertTrue(OutboxStore.belongs(a, to: userA))
        XCTAssertFalse(OutboxStore.belongs(a, to: userB), "B may send A's work")
        XCTAssertFalse(OutboxStore.belongs(a, to: nil), "nobody-known may send A's work")
        XCTAssertTrue(OutboxStore.belongs(legacy, to: userB), "an unowned row is the signed-in user's")
        XCTAssertFalse(OutboxStore.belongs(legacy, to: nil))
    }

    /// With no identity known, nothing is shown and nothing is sent.
    func testNothingIsShownOrSentWhileNobodyIsKnown() async {
        let identity = makeIdentity(FakeKeychain())
        let sent = Sent()
        let (outbox, queue) = makeOutbox(identity: identity, sent: sent)
        await queue.enqueue(operation(owner: userA, summary: "a"))
        await queue.enqueue(operation(owner: nil, summary: "legacy"))
        await outbox.flush()
        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertTrue(sent.ids.isEmpty)
        let all = await queue.all()
        XCTAssertEqual(all.count, 2, "fail-closed must not mean drop")
        XCTAssertNil(all.first { $0.parcelSummary == "legacy" }?.ownerUserID,
                     "an unowned row was claimed by nobody")
    }

    /// A row written before `ownerUserID` existed still DECODES — a
    /// non-optional field would throw `keyNotFound` and `all()`'s `try?`
    /// would hide every one — and is CLAIMED by the next signed-in user, so
    /// it cannot wander to a third account later.
    func testARowFromBeforeOwnershipDecodesAndIsClaimedOnce() async throws {
        let legacy = operation(owner: nil, summary: "legacy")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "ownerUserID")
        XCTAssertNil(json["ownerUserID"], "positive control: this is an old row's shape")
        let decoded = try JSONDecoder().decode(
            PendingOperation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.ownerUserID)

        let keychain = FakeKeychain()
        let identity = makeIdentity(keychain)
        let sent = Sent()
        let (outbox, queue) = makeOutbox(identity: identity, sent: sent)
        await queue.enqueue(decoded)

        identity.adopt(userB)
        await outbox.refresh()
        XCTAssertEqual(outbox.pending.map(\.id), [legacy.id])
        let claimed = await queue.all()
        XCTAssertEqual(claimed.first?.ownerUserID, userB, "the next signed-in user did not claim it")

        // Now it is B's, and A does not get it.
        identity.adopt(userA)
        await outbox.refresh()
        XCTAssertTrue(outbox.pending.isEmpty, "a claimed row moved on to another account")
    }

    /// A sign-out DURING a drain stops the drain at the next item, rather
    /// than sending the rest of A's list under whoever signs in next.
    func testASignOutMidDrainStopsTheDrain() async {
        let keychain = FakeKeychain()
        let identity = makeIdentity(keychain)
        identity.adopt(userA)
        let queue = PendingOperations(directoryName: "SignOutHygiene-\(UUID().uuidString)")
        var sentIDs: [String] = []
        let outbox = OutboxStore(
            queue: queue,
            currentOwner: { identity.userID },
            identify: {},
            send: { item in
                sentIDs.append(item.id)
                // Изход, and B signs in, while the first send is in flight.
                identity.clear()
                identity.adopt("user-b-0002")
            }
        )
        let first = operation(owner: userA, summary: "1")
        let second = operation(owner: userA, summary: "2")
        await queue.enqueue(first)
        await queue.enqueue(second)
        await outbox.flush()
        XCTAssertEqual(sentIDs, [first.id], "the drain kept sending A's work after B signed in")
        let left = await queue.all()
        XCTAssertEqual(left.map(\.id), [second.id], "A's unsent work was dropped")
        XCTAssertTrue(outbox.pending.isEmpty, "B's banner shows A's work after the drain")
    }

    // MARK: - work in flight across Изход

    /// A page fetched under A that lands after Изход is dropped.
    func testAnUnreadPageFromTheOldSessionIsDropped() {
        let store = ExchangeUnreadStore()
        let stale = SessionEpoch.current
        store.apply([thread("x")], asOf: stale)
        XCTAssertEqual(store.count, 1, "positive control: a current page applies")
        store.reset()
        SessionEpoch.advance()
        store.apply([thread("x"), thread("y")], asOf: stale)
        XCTAssertEqual(store.count, 0, "A's inbox page landed in B's badge")
    }

    /// A refresh that ANSWERS after Изход must neither write A's new pair back
    /// into the emptied Keychain nor, if refused, clear the next user's.
    func testARefreshThatLandsAfterTheSessionChangedCommitsNothing() {
        let a = Tokens(accessToken: "a", refreshToken: "ra", expiresAt: .distantFuture)
        let b = Tokens(accessToken: "b", refreshToken: "rb", expiresAt: .distantFuture)
        XCTAssertTrue(APIClient.mayCommitRefresh(seen: a, stored: a), "positive control")
        XCTAssertFalse(APIClient.mayCommitRefresh(seen: a, stored: nil),
                       "a refresh after Изход resurrects A's session")
        XCTAssertFalse(APIClient.mayCommitRefresh(seen: a, stored: b),
                       "A's refused refresh clears B's tokens")

        let api = read("Agrent/API/APIClient.swift")
        XCTAssertEqual(api.components(separatedBy: "TokenStore.save(").count - 1, 1,
                       "positive control: one save in the refresh path")
        let guarded = #"if Self\.mayCommitRefresh\(seen: seen, stored: TokenStore\.load\(\)\) \{\s*TokenStore\.%@"#
        XCTAssertNotNil(api.range(of: String(format: guarded, #"save\(fresh\)"#), options: .regularExpression),
                        "the refresh saves without checking the session is still its own")
        XCTAssertNotNil(api.range(of: String(format: guarded, #"clear\(\)"#), options: .regularExpression),
                        "a refused refresh clears without checking the session is still its own")
        XCTAssertEqual(api.components(separatedBy: "TokenStore.clear()").count - 1, 1,
                       "a second, unguarded clear in the refresh path")
    }

    /// `/me` and a bar save that answer after Изход write nothing. No runtime
    /// hook short of a network, so the guards are read.
    func testInFlightIdentityAndBarSaveAreEpochGuarded() {
        let me = read("Agrent/API/CurrentUser.swift")
        guard let capture = me.range(of: "let epoch = SessionEpoch.current"),
              let guardLine = me.range(of: "guard SessionEpoch.isCurrent(epoch) else { return nil }"),
              let assign = me.range(of: "user = resolved") else {
            return XCTFail("positive control: CurrentUserStore.load captures and checks the epoch")
        }
        XCTAssertLessThan(capture.lowerBound, guardLine.lowerBound)
        XCTAssertLessThan(guardLine.lowerBound, assign.lowerBound,
                          "a /me resolved after Изход is written before the check")
        XCTAssertTrue(me.contains("SessionIdentity.shared.adopt(resolved.id)"),
                      "the identity is not adopted from /me")

        let tabs = read("Agrent/Tabs/BottomTabsStore.swift")
        guard let check = tabs.range(of: "guard SessionEpoch.isCurrent(epoch) else { return false }"),
              let rollback = tabs.range(of: "stored = previous") else {
            return XCTFail("positive control: the save's rollback is guarded")
        }
        XCTAssertLessThan(check.lowerBound, rollback.lowerBound,
                          "a failed save after Изход restores A's bar for B")

        let inbox = read("Agrent/Exchange/MessagingStores.swift")
        XCTAssertFalse(inbox.contains("ExchangeUnreadStore.shared.apply(page.threads)\n"),
                       "the inbox applies its page without an epoch")
    }

    // MARK: - the response cache

    /// No identity, no cache — and a response that lands after the session
    /// changed is not written.
    func testTheCacheIsOffWithoutAnIdentityAndChecksBeforeWriting() {
        XCTAssertNil(CacheScope.current(identity: makeIdentity(FakeKeychain())))
        let keychain = FakeKeychain()
        keychain.owner = userA
        XCTAssertEqual(CacheScope.current(identity: makeIdentity(keychain))?.userID, userA,
                       "positive control: a stored owner is loaded")

        let source = read("Agrent/Core/CachedResource.swift")
        XCTAssertTrue(source.contains("guard let scope = CacheScope.current() else {"),
                      "the cache-first path reads with no identity")
        guard let check = source.range(of: "if let key, CacheScope.current() == scope {"),
              let write = source.range(of: "await ResponseCache.shared.write(key, data)") else {
            return XCTFail("positive control: the write is guarded by the scope it was read under")
        }
        XCTAssertLessThan(check.lowerBound, write.lowerBound)
        XCTAssertFalse(source.contains("key(tenant:"), "a cache key without a user is back")
    }

    // MARK: - the identity

    func testTheIdentityPersistsAndClearsWithTheTokens() {
        let keychain = FakeKeychain()
        let identity = makeIdentity(keychain)
        XCTAssertNil(identity.userID)
        identity.adopt(userA)
        XCTAssertEqual(keychain.owner, userA)
        XCTAssertEqual(makeIdentity(keychain).userID, userA, "a relaunch forgets who is signed in")
        identity.adopt(userB)
        XCTAssertEqual(keychain.owner, userB, "the server's answer did not replace a stale owner")
        identity.clear()
        XCTAssertNil(keychain.owner)

        let tokens = read("Agrent/Auth/TokenStore.swift")
        guard let clear = tokens.range(of: "static func clear() {") else {
            return XCTFail("positive control: TokenStore.clear exists")
        }
        let body = tokens[clear.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("SessionIdentity.shared.clear()"),
                      "tokens can be cleared and leave their owner behind")
    }

    // MARK: - sign-out and sign-in, as written

    /// Local first, whole, and with no network in front of it; the revoke is
    /// a seam after it; the web's cookie logout is nowhere.
    func testSignOutIsLocalFirstAndTheRevokeIsASeam() throws {
        let auth = read("Agrent/Auth/AuthClient.swift")
        guard let start = auth.range(of: "func signOut() {"),
              let end = auth.range(of: "// MARK: - internals") else {
            return XCTFail("positive control: signOut is where this expects it")
        }
        let signOut = String(auth[start.upperBound..<end.lowerBound])
        // The real path is the one after the seam's `#endif`.
        let real = try XCTUnwrap(signOut.components(separatedBy: "#endif").last)
        guard let local = real.range(of: "SessionReset.endSession()"),
              let revoke = real.range(of: "SessionRevocation.revokeThisDevice("),
              let flip = real.range(of: "state = .signedOut") else {
            return XCTFail("signOut no longer resets, revokes and flips, in that shape")
        }
        XCTAssertLessThan(local.lowerBound, revoke.lowerBound, "the revoke runs before the local clear")
        XCTAssertLessThan(revoke.lowerBound, flip.lowerBound)
        XCTAssertFalse(real.contains("await "), "sign-out waits on something")

        // Nothing in the app CALLS the web's cookie logout. Comments may name
        // it — two do, to say why not — so they are stripped first, and the
        // positive control is that the stripped-out mention exists.
        XCTAssertTrue(auth.contains("/api/auth/logout"), "positive control: the reason is written down")
        XCTAssertFalse(appSources().contains { Self.code($0.text).contains("/api/auth/logout") },
                       "/api/auth/logout clears a web cookie and revokes nothing native")

        // The seam names its endpoint and does nothing yet.
        let reset = read("Agrent/Auth/SessionReset.swift")
        guard let seam = reset.range(of: "static func revokeThisDevice(refreshToken: String?) {") else {
            return XCTFail("positive control: the revoke seam exists")
        }
        let seamBody = String(reset[seam.upperBound...].prefix(300))
        XCTAssertTrue(seamBody.contains("TODO(agri-saas#1191 P0.9): POST /api/auth/native/revoke"))
        for request in ["APIClient", "URLSession", "NoURLCache", "Task"] {
            XCTAssertFalse(seamBody.contains(request),
                           "the revoke seam now does \(request) work — update this test with the contract")
        }
    }

    /// A sign-in starts from nothing, before the new pair is saved.
    func testSignInStartsFromNothing() {
        let auth = read("Agrent/Auth/AuthClient.swift")
        guard let fresh = auth.range(of: "SessionReset.beginFreshSession()"),
              let save = auth.range(of: "TokenStore.save(Tokens(") else {
            return XCTFail("positive control: the exchange resets, then saves")
        }
        XCTAssertLessThan(fresh.lowerBound, save.lowerBound,
                          "the reset runs after the new tokens are saved and would clear them")
    }

    /// Every queued operation is stamped with who recorded it.
    func testTheSheetStampsTheOwner() {
        XCTAssertTrue(read("Agrent/Locations/ParcelOperationSheet.swift")
            .contains("ownerUserID: me?.id"), "a queued operation has no owner")
    }

    // MARK: - the singleton guard

    /// Singletons a sign-out deliberately does NOT reset, each with where it
    /// is handled instead. Everything else found must be called in
    /// `SessionReset.resetUserState()`.
    private static let notReset: [String: String] = [
        "APIClient.shared": "no user data; its in-flight refresh is guarded by mayCommitRefresh",
        "ResponseCache.shared": "purged by endSession and keyed on CacheScope",
        "PendingOperations.shared": "parked by owner, never cleared",
        "SessionIdentity.shared": "cleared by endSession and TokenStore.clear",
    ]

    /// A type's instance of ITSELF held in a static — `static let messages =
    /// RateLimitPause()` inside `RateLimitPause` — plus anything spelled
    /// `static … shared`, however it is built.
    ///
    /// Keyed on "the type stores itself" rather than on any `= Something()`,
    /// because `Trace`'s `static let lock = NSLock()` and `start = Date()` are
    /// values, not app-wide stores, and a guard that fires on them teaches the
    /// next person to work around it.
    /// The source with every `//` comment removed — a comment that SAYS
    /// `static let shared`, or names a route, is not code that does either.
    ///
    /// A comment starts at a `//` with whitespace (or nothing) before it, so
    /// the `//` of `"https://…/api/auth/logout"` in a string literal is NOT
    /// taken for one — that is exactly the call this must still see.
    static func code(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"(?m)(^|\s)//.*$"#, with: "$1", options: .regularExpression)
    }

    static func singletons(in raw: String) -> Set<String> {
        let source = code(raw)
        var found = Set<String>()
        let typeDecl = try! NSRegularExpression(
            pattern: #"(?:class|actor|struct|enum|extension)\s+([A-Z]\w*)"#)
        let single = try! NSRegularExpression(
            pattern: #"static\s+(?:let|var)\s+(\w+)\b(?:\s*(?::\s*[\w.]+\s*)?=\s*([A-Z]\w*)\(\))?"#)
        let ns = source as NSString
        let all = NSRange(location: 0, length: ns.length)
        let decls = typeDecl.matches(in: source, range: all)
        for match in single.matches(in: source, range: all) {
            let name = ns.substring(with: match.range(at: 1))
            // The owning type is the nearest declaration above the match.
            guard let decl = decls.last(where: { $0.range.location < match.range.location }) else { continue }
            let owner = ns.substring(with: decl.range(at: 1))
            let built = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            if name == "shared" || built == owner {
                found.insert("\(owner).\(name)")
            }
        }
        return found
    }

    /// A NEW user-data singleton cannot be added without joining the reset
    /// list (or being argued into `notReset` above, in review).
    func testEverySingletonIsAccountedFor() {
        let found = appSources().reduce(into: Set<String>()) { $0.formUnion(Self.singletons(in: $1.text)) }

        // Positive control: the scan sees the ones that exist today.
        let known: Set<String> = [
            "CurrentUserStore.shared", "BottomTabsStore.shared", "ExchangeUnreadStore.shared",
            "OutboxStore.shared", "RateLimitPause.messages", "DashboardPreferences.shared",
            "APIClient.shared", "ResponseCache.shared", "PendingOperations.shared",
            "SessionIdentity.shared",
        ]
        XCTAssertTrue(known.isSubset(of: found), "the scan misses: \(known.subtracting(found).sorted())")

        let reset = read("Agrent/Auth/SessionReset.swift")
        guard let start = reset.range(of: "static func resetUserState() {"),
              let end = reset[start.upperBound...].range(of: "\n    }\n") else {
            return XCTFail("positive control: resetUserState is where this expects it")
        }
        let body = reset[start.upperBound..<end.lowerBound]
        for singleton in found.sorted() where Self.notReset[singleton] == nil {
            XCTAssertTrue(body.contains("\(singleton)."),
                          "\(singleton) holds state across sign-out and is not in "
                          + "SessionReset.resetUserState() — reset it there, or argue it into notReset")
        }
        for exempt in Self.notReset.keys {
            XCTAssertTrue(found.contains(exempt), "\(exempt) is exempted but no longer exists")
        }
    }

    /// The mutation proof: the matcher flags a singleton it has never seen,
    /// in both spellings the app uses.
    func testTheSingletonScanCatchesANewOne() {
        let added = """
        @Observable
        @MainActor
        final class FarmFlagsStore {
            static let shared = FarmFlagsStore()
            private init() {}
        }
        actor InboxCache {
            static let shared: InboxCache = { InboxCache() }()
        }
        enum Palette { static let accent = Color(hex: 0x0) }
        """
        XCTAssertEqual(Self.singletons(in: added), ["FarmFlagsStore.shared", "InboxCache.shared"],
                       "a value constant was taken for a singleton, or a singleton was missed")

        // And the comment stripper keeps a URL's `//` while dropping a comment.
        let call = #"let u = URL(string: "https://h/api/auth/logout") // not this"#
        XCTAssertTrue(Self.code(call).contains("/api/auth/logout"), "a real call was stripped as a comment")
        XCTAssertFalse(Self.code("    /// static let shared = X()").contains("shared"))
    }

    // MARK: - helpers

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    private func appSources() -> [(path: String, text: String)] {
        let dir = root.appendingPathComponent("Agrent")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.path, $0) }
            }
    }
}
