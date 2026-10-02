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

    /// `load()` and `refresh()` coalesce in BOTH directions through ONE slot.
    /// `load()` cannot be driven here without a network — its producer is the
    /// cache-first reader — so this is read from the source.
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
