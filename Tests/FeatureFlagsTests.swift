import XCTest
@testable import Agrent

/// `FeatureFlags` (agri-saas#1209) and the revoke request (agri-saas#1206),
/// both parts of agri-saas#1191 P0.9.
///
/// The flags half is mostly about what is OFF, because that is where a client
/// gets a dark-launch rail wrong: by reading `{}` as "no answer, use
/// defaults", which turns the server's kill switch into an ON switch.
@MainActor
final class FeatureFlagsTests: XCTestCase {

    override func tearDown() {
        FeatureFlags.shared.reset()
        super.tearDown()
    }

    // MARK: - isOn

    func testOnlyAPresentTrueIsOn() {
        let flags = FeatureFlags()
        flags.adopt(["social.dm": true, "social.profiles": false])
        XCTAssertTrue(flags.isOn("social.dm"), "positive control")
        XCTAssertFalse(flags.isOn("social.profiles"), "false is off")
        XCTAssertFalse(flags.isOn("social.feed"), "an ABSENT key is off")
        XCTAssertFalse(flags.isOn("social"), "a prefix of a dotted key is not that key")
        XCTAssertFalse(flags.isOn("SOCIAL.DM"), "keys are exact, case included")
    }

    /// A fresh store has no defaults, and none of them true.
    func testAFreshStoreIsAllOff() {
        let flags = FeatureFlags()
        XCTAssertTrue(flags.resolved.isEmpty)
        XCTAssertFalse(flags.isOn("social.dm"))
    }

    /// `{}` is the global kill switch. It REPLACES whatever was on.
    func testAnEmptyObjectTurnsEverythingOff() {
        let flags = FeatureFlags()
        flags.adopt(["social.dm": true])
        XCTAssertTrue(flags.isOn("social.dm"), "positive control")
        flags.adopt([:])
        XCTAssertFalse(flags.isOn("social.dm"), "{} was read as 'keep the previous answer'")
    }

    /// No `featureFlags` key at all (a server before #1209) is all off — not
    /// "keep what you had", and not defaults.
    func testAnAbsentFeatureFlagsKeyIsAllOff() {
        let flags = FeatureFlags()
        flags.adopt(["social.dm": true])
        flags.adopt(nil)
        XCTAssertFalse(flags.isOn("social.dm"))
        XCTAssertTrue(flags.resolved.isEmpty)
    }

    /// Sign-out clears them, through the real reset list.
    func testSignOutClearsTheFlags() {
        FeatureFlags.shared.adopt(["social.dm": true])
        XCTAssertTrue(FeatureFlags.shared.isOn("social.dm"), "positive control")
        SessionReset.resetUserState()
        XCTAssertFalse(FeatureFlags.shared.isOn("social.dm"), "A's flags survived sign-out")
    }

    // MARK: - decoding `/me`

    private func me(_ tail: String) async throws -> CurrentUser {
        let json = #"{"user":{"id":"u1","name":"А","email":null,"role":"OWNER"},"tenant":null"#
            + tail + "}"
        return try await MeAPI.decode(from: Data(json.utf8))
    }

    func testTheEnvelopeRootCarriesTheFlags() async throws {
        let user = try await me(#","featureFlags":{"social.dm":true,"social.profiles":false}"#)
        XCTAssertEqual(user.featureFlags, ["social.dm": true, "social.profiles": false])
        XCTAssertEqual(user.id, "u1")
    }

    /// `{}` decodes as an EMPTY map, distinct from "absent" on the wire —
    /// and both land on all off.
    func testEmptyAndAbsentDecodeDistinctlyAndBothMeanOff() async throws {
        let empty = try await me(#","featureFlags":{}"#)
        let absent = try await me("")
        let null = try await me(#","featureFlags":null"#)
        XCTAssertEqual(empty.featureFlags, [:])
        XCTAssertNil(absent.featureFlags)
        XCTAssertNil(null.featureFlags)
        for user in [empty, absent, null] {
            let flags = FeatureFlags()
            flags.adopt(user.featureFlags)
            XCTAssertFalse(flags.isOn("social.dm"))
        }
    }

    /// A flags map this build cannot read costs the FLAGS, never the identity:
    /// `/me` failing would leave the spray sheet without an `assigneeUserId`.
    func testAMalformedMapIsAllOffAndTheUserStillDecodes() async throws {
        let user = try await me(#","featureFlags":{"social.dm":"yes"}"#)
        XCTAssertEqual(user.id, "u1")
        XCTAssertNil(user.featureFlags)
        let list = try await me(#","featureFlags":["social.dm"]"#)
        XCTAssertNil(list.featureFlags)
    }

    /// Only a FRESH `/me` reaches the store — the cached copy on disk may be
    /// from a previous launch, and stale flags are a kill switch that did not
    /// arrive. Source, because the policy is one line inside `load()`'s
    /// publish closure and has no seam of its own.
    func testOnlyAFreshMeIsAdopted() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Agrent/API/CurrentUser.swift"),
                                encoding: .utf8)
        let code = SignOutHygieneTests.code(source)
        XCTAssertTrue(code.contains("if case .loaded(let value, .fresh) = state { freshFlags = .some(value.featureFlags) }"),
                      "flags are taken from a publish that is not known to be fresh")
        // One adoption site, `commit`, behind both producers. The store's
        // `flags` is `FeatureFlags.shared` in the app (the init's fallback).
        XCTAssertEqual(code.components(separatedBy: "flags.adopt(").count - 1, 1,
                       "a second adoption site — check it is fresh-only too")
        XCTAssertTrue(code.contains("if let freshFlags { flags.adopt(freshFlags) }"))
        XCTAssertTrue(code.contains("self.flags = flags ?? FeatureFlags.shared"))
        // The second producer, the foreground refresh: fresh or nothing.
        XCTAssertTrue(code.contains("guard case .loaded(let fresh, .fresh) = answer else {"),
                      "refresh() adopts flags from an answer not known to be fresh")
        XCTAssertTrue(code.contains("commit(fresh, freshFlags: .some(fresh.featureFlags))"))
        // Nothing writes flags to disk: no UserDefaults / AppStorage in the store.
        let store = try String(contentsOf: root.appendingPathComponent("Agrent/Core/FeatureFlags.swift"),
                               encoding: .utf8)
        for persist in ["UserDefaults", "@AppStorage", "ResponseCache.shared", "FileManager"] {
            XCTAssertFalse(SignOutHygieneTests.code(store).contains(persist),
                           "FeatureFlags persists via \(persist); flags are session state")
        }
    }

    // MARK: - the revoke request

    func testTheRevokeRequestIsTheContract() throws {
        let base = try XCTUnwrap(URL(string: "https://example.invalid"))
        let req = SessionRevocation.request(refreshToken: "rt-123", baseURL: base)
        XCTAssertEqual(req.url?.absoluteString, "https://example.invalid/api/auth/native/revoke")
        XCTAssertEqual(SessionRevocation.path, "/api/auth/native/revoke")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // NO_AUTH in the spec: the refresh token in the body is the credential.
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(req.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["refreshToken": "rt-123"], "the route reads `refreshToken` and nothing else")
    }
}
