import SwiftUI
import XCTest
@testable import Agrent

/// `CurrentUserStore.refresh()` — `/me`, and with it the flags, re-read on
/// every return to the foreground (owner decision 2026-10-02).
///
/// Every store here is a fresh instance with a fake `/me`, its own
/// `FeatureFlags` and a memory-only `SessionIdentity`, so nothing reaches the
/// network, the Keychain or the app's singletons. The fake SUSPENDS until the
/// test answers, which is what lets a sign-out or a second caller land while
/// the request is in flight.
@MainActor
final class CurrentUserRefreshTests: XCTestCase {

    /// A `/me` that answers when told to, and counts how often it was asked.
    @MainActor
    private final class FakeMe {
        private(set) var calls = 0
        private var waiting: [CheckedContinuation<LoadState<CurrentUser>, Never>] = []

        func fetch() async -> LoadState<CurrentUser> {
            calls += 1
            return await withCheckedContinuation { waiting.append($0) }
        }

        /// `load()`'s producer, counted in the SAME tally: a cache-first read
        /// is one network `/me` too. The answer is folded as the real one
        /// folds it — the user from any value, the flags from `.fresh` only.
        func fetchCacheFirst() async -> CurrentUserStore.Resolution {
            let state = await fetch()
            var resolution = CurrentUserStore.Resolution(user: state.value)
            if case .loaded(let value, .fresh) = state { resolution.freshFlags = .some(value.featureFlags) }
            return resolution
        }

        func answer(_ state: LoadState<CurrentUser>) {
            let all = waiting
            waiting = []
            for continuation in all { continuation.resume(returning: state) }
        }

        /// Until `n` requests are parked. Bounded, so a regression fails the
        /// test rather than hanging the suite.
        func waitForCalls(_ n: Int) async {
            for _ in 0..<1_000 where calls < n { await Task.yield() }
        }
    }

    private var me: FakeMe!
    private var flags: FeatureFlags!
    private var identity: SessionIdentity!
    private var adoptedTabs: [CurrentUser] = []
    private var store: CurrentUserStore!

    override func setUp() {
        super.setUp()
        me = FakeMe()
        flags = FeatureFlags()
        identity = SessionIdentity(load: { nil }, save: { _ in })
        adoptedTabs = []
        store = CurrentUserStore(
            fetchCacheFirst: { [unowned self] in await self.me.fetchCacheFirst() },
            fetchFresh: { [unowned self] in await self.me.fetch() },
            identity: identity,
            flags: flags,
            adoptTabs: { [unowned self] in self.adoptedTabs.append($0) }
        )
    }

    private func user(_ id: String, flags: [String: Bool]?, tabs: [String]? = nil,
                      role: String? = "OWNER") -> CurrentUser {
        CurrentUser(id: id, name: nil, email: nil, role: role, bottomTabOrder: tabs, featureFlags: flags)
    }

    // MARK: - adoption

    /// Past the memo: a store that already holds a user still asks, and the
    /// fresh answer replaces user, flags, identity and bar.
    func testARefreshAdoptsTheFreshAnswer() async {
        store.adoptForTesting(user("u1", flags: nil))
        flags.adopt(["social.dm": true])

        let refreshed = user("u1", flags: ["social.dm": false, "social.feed": true],
                             tabs: ["map"], role: "MECHANISATOR")
        let pending = Task { await store.refresh() }
        await me.waitForCalls(1)
        XCTAssertEqual(me.calls, 1, "refresh() returned the memoised user without asking")
        me.answer(.loaded(refreshed, .fresh))
        let result = await pending.value

        XCTAssertEqual(result, refreshed)
        XCTAssertEqual(store.user, refreshed)
        XCTAssertFalse(flags.isOn("social.dm"), "a flag the server turned off is still on")
        XCTAssertTrue(flags.isOn("social.feed"), "a flag the server turned on did not arrive")
        XCTAssertEqual(identity.userID, "u1")
        XCTAssertEqual(adoptedTabs, [refreshed], "the bar did not adopt the fresh order")
    }

    /// `{}` on a refresh is the kill switch arriving at a running app.
    func testARefreshCarriesTheKillSwitch() async {
        flags.adopt(["social.dm": true])
        let pending = Task { await store.refresh() }
        await me.waitForCalls(1)
        me.answer(.loaded(user("u1", flags: [:]), .fresh))
        _ = await pending.value
        XCTAssertFalse(flags.isOn("social.dm"))
    }

    // MARK: - failure

    /// Offline at the edge of a field: the session's fresh flags and its user
    /// stand. Turning them off would make a surface blink out on every
    /// foreground without signal.
    func testAFailedRefreshKeepsTheUserAndTheFlags() async {
        let held = user("u1", flags: nil, tabs: ["journal"])
        store.adoptForTesting(held)
        flags.adopt(["social.dm": true])

        let pending = Task { await store.refresh() }
        await me.waitForCalls(1)
        me.answer(.failed("offline"))
        let result = await pending.value

        XCTAssertEqual(result, held, "a failed refresh returned something other than what was held")
        XCTAssertEqual(store.user, held, "a failed refresh dropped the user")
        XCTAssertTrue(flags.isOn("social.dm"), "a failed refresh turned the flags off")
        XCTAssertTrue(adoptedTabs.isEmpty, "a failed refresh touched the bar")
    }

    /// A `.stale` answer is a disk copy — never a source of flags.
    func testAStaleAnswerIsNotAdopted() async {
        flags.adopt(["social.dm": true])
        let pending = Task { await store.refresh() }
        await me.waitForCalls(1)
        me.answer(.loaded(user("u1", flags: [:]), .stale(since: .distantPast)))
        _ = await pending.value
        XCTAssertTrue(flags.isOn("social.dm"), "flags were adopted from a cached /me")
        XCTAssertNil(store.user)
    }

    // MARK: - sign-out

    /// Started under A, answered after Изход: nothing of it lands.
    func testARefreshThatLandsAfterSignOutIsDropped() async {
        store.adoptForTesting(user("a", flags: nil))
        let pending = Task { await store.refresh() }
        await me.waitForCalls(1)

        store.clear()
        SessionEpoch.advance()
        me.answer(.loaded(user("a", flags: ["social.dm": true], tabs: ["map"]), .fresh))
        let result = await pending.value

        XCTAssertNil(result)
        XCTAssertNil(store.user, "A's /me landed after sign-out")
        XCTAssertFalse(flags.isOn("social.dm"), "A's cohort reached the next session")
        XCTAssertNil(identity.userID, "A's identity was re-adopted after sign-out")
        XCTAssertTrue(adoptedTabs.isEmpty, "A's bar was restored after sign-out")
    }

    // MARK: - coalescing

    /// Two returns in quick succession, or a return while launch is reading:
    /// one request, one answer for both.
    func testConcurrentRefreshesShareOneRequest() async {
        let first = Task { await store.refresh() }
        await me.waitForCalls(1)
        let second = Task { await store.refresh() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(me.calls, 1, "a second refresh fired a second /me")

        let answer = user("u1", flags: ["social.dm": true])
        me.answer(.loaded(answer, .fresh))
        let a = await first.value
        let b = await second.value
        XCTAssertEqual(a, answer)
        XCTAssertEqual(b, answer)
        XCTAssertEqual(adoptedTabs.count, 1, "one answer was adopted twice")

        // And the slot is released: the NEXT return asks again.
        let third = Task { await store.refresh() }
        await me.waitForCalls(2)
        XCTAssertEqual(me.calls, 2, "the in-flight slot was never released")
        me.answer(.failed("offline"))
        _ = await third.value
    }

    // MARK: - exactly one /me per launch and per foreground

    /// Every caller a COLD LAUNCH has, at once, in the order they start:
    ///
    ///   · `MainTabView.task`'s `load()`               — the launch's own read
    ///   · `OutboxStore.identify`'s `load()`            — the launch flush
    ///   · `OfflinePrefetch.warm`'s `settled()`         — the launch warm
    ///   · `FarmRiskStore`, `ParcelMapView`,
    ///     `ParcelOperationSheet`'s `load()`            — screens opened early
    ///
    /// (`AuthClient`'s `load()` is the sign-in path's version of the first
    /// line: it runs before `MainTabView` exists, which then finds the memo.)
    /// One request. Then, with the user held, every one of them again asks
    /// nothing.
    func testAColdLaunchSendsExactlyOneMe() async {
        let launch = Task { await store.load() }
        await me.waitForCalls(1)
        let others = [
            Task { await store.load() },      // outbox identify
            Task { await store.settled() },   // prefetch
            Task { await store.load() },      // FarmRiskStore
            Task { await store.load() },      // ParcelMapView
            Task { await store.load() },      // ParcelOperationSheet
        ]
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(me.calls, 1, "a cold launch sent more than one /me")

        let answer = user("u1", flags: ["social.dm": true])
        me.answer(.loaded(answer, .fresh))
        let first = await launch.value
        XCTAssertEqual(first, answer)
        for other in others {
            let value = await other.value
            XCTAssertEqual(value, answer, "a coalesced caller got a different answer")
        }
        XCTAssertTrue(flags.isOn("social.dm"), "positive control: the launch's fresh /me adopted flags")
        XCTAssertNotNil(flags.lastFreshAt, "the fresh adoption was not stamped")

        // Late callers, the memo: still one.
        _ = await store.load()
        _ = await store.settled()
        XCTAssertEqual(me.calls, 1, "a caller after the launch's answer asked again")
    }

    /// An OFFLINE cold launch still sends one: the prefetch finds no user and
    /// no request in flight and must NOT start one — that is the case where
    /// a `load()` there would have sent a second `/me` into a dead link.
    func testAnOfflineColdLaunchSendsExactlyOneMe() async {
        let launch = Task { await store.load() }
        await me.waitForCalls(1)
        me.answer(.failed("offline"))
        let resolved = await launch.value
        XCTAssertNil(resolved)

        let prefetch = await store.settled()
        XCTAssertNil(prefetch)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(me.calls, 1, "the prefetch asked for /me itself")
        XCTAssertNil(flags.lastFreshAt, "a launch with no fresh answer stamped one")
    }

    /// Each RETURN to the foreground, as the scenePhase handler runs it: the
    /// flush (`identify` → `load()`), the prefetch (`settled()`), and the
    /// gated `refresh()` — started together. One request per return, three
    /// returns in a row, and each one's answer is the one adopted.
    func testEachReturnToTheForegroundSendsExactlyOneMe() async throws {
        store.adoptForTesting(user("u1", flags: nil))
        var stamp = Date.distantPast
        for n in 1...3 {
            let refresh = Task { await store.refresh() }
            let identify = Task { await store.load() }
            let prefetch = Task { await store.settled() }
            await me.waitForCalls(n)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(me.calls, n, "return \(n) sent more than one /me")

            let answer = user("u1", flags: ["social.dm": n.isMultiple(of: 2)])
            me.answer(.loaded(answer, .fresh))
            _ = await refresh.value
            _ = await identify.value
            _ = await prefetch.value
            XCTAssertEqual(flags.isOn("social.dm"), n.isMultiple(of: 2), "return \(n)'s answer was not adopted")
            // The diagnostics clock moves with each fresh answer — the
            // number the owner's propagation measurement reads.
            let now = try XCTUnwrap(flags.lastFreshAt, "return \(n)'s fresh answer was not stamped")
            XCTAssertGreaterThanOrEqual(now, stamp)
            stamp = now
        }
        XCTAssertEqual(me.calls, 3)
    }

    /// The return after an OFFLINE launch: there is no user, so the flush's
    /// `identify` STARTS a `load()` — and the handler's `refresh()` must join
    /// it rather than send its own. Whichever starts first is the request.
    func testAReturnAfterAnOfflineLaunchStillSendsOne() async {
        let launch = Task { await store.load() }
        await me.waitForCalls(1)
        me.answer(.failed("offline"))
        _ = await launch.value

        let identify = Task { await store.load() }
        await me.waitForCalls(2)
        let refresh = Task { await store.refresh() }
        let prefetch = Task { await store.settled() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(me.calls, 2, "identify and refresh each sent a /me")

        let answer = user("u1", flags: ["social.dm": true])
        me.answer(.loaded(answer, .fresh))
        let a = await identify.value
        let b = await refresh.value
        let c = await prefetch.value
        XCTAssertEqual([a, b, c], [answer, answer, answer])
        XCTAssertTrue(flags.isOn("social.dm"))
    }

    /// The counts above hold only if nothing reaches `/api/auth/me` except
    /// through this store's two producers. So: `MeAPI.path`, its decoder and
    /// the literal path appear in the app's CODE (comments stripped) inside
    /// `CurrentUser.swift` only, and the store is built only once.
    ///
    /// One named exception: `FixtureCatalogue` maps the path to a fixture
    /// file for the UI-test seam. That is a table key, not a fetch — it is
    /// allowed as that exact text and nothing else in that file.
    ///
    /// This is what `OfflinePrefetch.warm` failed until this change: its
    /// `CachedResource.load(MeAPI.path)` was the second `/me` on every
    /// foreground.
    func testMeIsFetchedOnlyInsideCurrentUserSwift() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Agrent")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "positive control: the app's sources were found")

        let home = "CurrentUser.swift"
        let allowed = ["FixtureCatalogue.swift": "(MeAPI.path, \"auth-me\"),"]
        var homeHits = 0
        for file in files {
            var code = SignOutHygieneTests.code(try String(contentsOf: file, encoding: .utf8))
            if let ok = allowed[file.lastPathComponent] { code = code.replacingOccurrences(of: ok, with: "") }
            let hits = ["MeAPI.path", "MeAPI.decode", "\"/api/auth/me\"", "CurrentUserStore("]
                .map { code.components(separatedBy: $0).count - 1 }
            if file.lastPathComponent == home {
                homeHits = hits.reduce(0, +)
                XCTAssertEqual(hits[3], 1, "a second CurrentUserStore — a second in-flight slot")
            } else {
                XCTAssertEqual(hits.reduce(0, +), 0,
                               "\(file.lastPathComponent) reaches /me past CurrentUserStore")
            }
        }
        XCTAssertGreaterThan(homeHits, 3, "positive control: CurrentUser.swift's own /me was seen")

        let prefetch = SignOutHygieneTests.code(try String(
            contentsOf: app.appendingPathComponent("Core/OfflinePrefetch.swift"), encoding: .utf8))
        XCTAssertTrue(prefetch.contains("await CurrentUserStore.shared.settled()"),
                      "the prefetch no longer waits for the store's /me before warming")
        XCTAssertFalse(prefetch.contains("CurrentUserStore.shared.load()"),
                       "the prefetch can START a /me — an offline launch would send two")
    }

    /// `settled()` is the store's one entry that never starts a request.
    func testSettledNeverAsks() async {
        let nobody = await store.settled()
        XCTAssertNil(nobody)
        store.adoptForTesting(user("u1", flags: nil))
        let held = await store.settled()
        XCTAssertEqual(held?.id, "u1")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(me.calls, 0)
    }

    /// `load()` and `refresh()` coalesce in BOTH directions through ONE slot —
    /// driven at runtime above; this keeps the shape that makes it so.
    func testLoadAndRefreshShareOneInFlightSlot() throws {
        let code = SignOutHygieneTests.code(try source("Agrent/API/CurrentUser.swift"))
        XCTAssertEqual(code.components(separatedBy: "private var inFlight: Task<").count - 1, 1,
                       "a second in-flight slot — load and refresh would race")
        guard let load = code.range(of: "func load() async -> CurrentUser? {"),
              let refresh = code.range(of: "func refresh() async -> CurrentUser? {") else {
            return XCTFail("positive control: both entry points exist")
        }
        let join = "if let inFlight { return await inFlight.value }"
        XCTAssertTrue(code[load.upperBound...].prefix(120).contains(join), "load() does not join a refresh")
        XCTAssertTrue(code[refresh.upperBound...].prefix(80).contains(join), "refresh() does not join a load")
    }

    // MARK: - when it runs

    /// A cold launch's first `.active` is not a return — the launch task is
    /// already reading `/me` — and neither is Control Centre.
    func testOnlyAReturnFromTheBackgroundCounts() {
        var gate = ForegroundReturn()
        XCTAssertFalse(gate.isReturn(to: .inactive))
        XCTAssertFalse(gate.isReturn(to: .active), "a cold launch reads /me twice")
        XCTAssertFalse(gate.isReturn(to: .inactive))
        XCTAssertFalse(gate.isReturn(to: .active), "Control Centre counted as leaving the app")
        XCTAssertFalse(gate.isReturn(to: .inactive))
        XCTAssertFalse(gate.isReturn(to: .background))
        XCTAssertFalse(gate.isReturn(to: .inactive))
        XCTAssertTrue(gate.isReturn(to: .active), "positive control: a real return refreshes")
        XCTAssertFalse(gate.isReturn(to: .active), "one return refreshed twice")
    }

    /// The foreground handler calls it, gated; the launch task does not.
    func testTheForegroundHandlerRefreshes() throws {
        let code = SignOutHygieneTests.code(try source("Agrent/AgrentApp.swift"))
        XCTAssertEqual(code.components(separatedBy: "CurrentUserStore.shared.refresh()").count - 1, 1,
                       "refresh() is called from somewhere besides the foreground handler")
        guard let handler = code.range(of: ".onChange(of: scenePhase) { _, phase in"),
              let gate = code.range(of: "if foreground.isReturn(to: phase), auth.state == .signedIn {"),
              let call = code.range(of: "Task { await CurrentUserStore.shared.refresh() }"),
              let launch = code.range(of: ".task {") else {
            return XCTFail("the scenePhase handler does not refresh /me behind the return gate")
        }
        XCTAssertLessThan(handler.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, call.lowerBound)
        XCTAssertLessThan(call.lowerBound, launch.lowerBound, "the refresh moved into the launch task")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
