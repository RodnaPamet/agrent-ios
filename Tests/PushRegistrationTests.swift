import XCTest
@testable import Agrent

/// This phone's APNs registration with each farm, and its removal at Изход
/// (agrent-ios#272; agri-saas #1789). No request leaves the process: the
/// registrar's sender and the removal's transport are both seams.
@MainActor
final class PushRegistrationTests: XCTestCase {
    /// 32 bytes, as APNs hands them over, with a byte below 0x10 so a
    /// one-digit rendering would show.
    private let token = Data((0..<32).map { UInt8($0 * 8) })
    private var hex: String { PushAPI.hex(token) }

    /// The registrar with a recording sender and a fixed farm list.
    private final class Sent {
        var calls: [String] = []
        var refuse: Set<String> = []
        /// The person's farms, changeable mid-test as a new sign-in changes them.
        var farms = ["ferma-1"]
    }

    private func registrar(_ sent: Sent, farms: @escaping @MainActor () -> [String]) -> PushRegistrar {
        PushRegistrar(
            register: { token, farm in
                sent.calls.append("\(farm) \(token.prefix(6))")
                if sent.refuse.contains(farm) { throw URLError(.notConnectedToInternet) }
            },
            farms: farms
        )
    }

    // MARK: - The wire

    /// The server pins the token to `^[0-9a-f]{64}$`; `Data.description`
    /// is not that shape and never promised one.
    func testTheTokenIsTwoLowercaseHexDigitsPerByte() throws {
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.hasPrefix("000810"), "a byte below 0x10 lost its leading zero: \(hex)")
        XCTAssertNil(hex.range(of: "[^0-9a-f]", options: .regularExpression), hex)
    }

    /// `ApnsRegistrationSchema`: `platform` is the literal `IOS`, which is
    /// what tells the route's union this is not a browser's subscription.
    /// `environment` in the wire's lower-case words (backend 2, 2026-10-20).
    func testTheBodyIsTheServersApnsShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(PushAPI.Registration(deviceToken: hex, environment: .development))
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"deviceToken":"\#(hex)","environment":"development","platform":"IOS"}"#)
        let production = try encoder.encode(PushAPI.Registration(deviceToken: hex, environment: .production))
        XCTAssertTrue(String(decoding: production, as: UTF8.self).contains(#""environment":"production""#))
        XCTAssertEqual(PushAPI.subscriptionsPath(in: "ferma-1"), "/api/t/ferma-1/push-subscriptions")
    }

    /// An unreadable profile leaves the key out, never sends `null` or a
    /// guess: the server reads a missing value as "the client did not say".
    func testAnUnknownEnvironmentIsLeftOut() throws {
        let body = try JSONEncoder().encode(PushAPI.Registration(deviceToken: hex, environment: nil))
        let sent = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(sent, ["platform": "IOS", "deviceToken": hex])
    }

    /// The removal is sent after the Keychain is cleared, so it carries the
    /// bearer it was given — and the client header, as every request does.
    func testTheRemovalCarriesItsOwnBearerAndTheSameBody() throws {
        let req = try PushAPI.removalRequest(hex, from: "ferma-1", accessToken: "access-A")
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.url?.path, "/api/t/ferma-1/push-subscriptions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer access-A")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "X-Agrent-Client"), "not stamped")
        XCTAssertEqual(req.timeoutInterval, 10)
        let sent = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(req.httpBody))
        XCTAssertEqual(sent, ["platform": "IOS", "deviceToken": hex])
    }

    // MARK: - Registering

    /// Every farm, once: a second sync with nothing new sends nothing, as
    /// the farm-list change that triggers one often changes nothing here.
    func testATokenIsRegisteredWithEveryFarmOnce() async {
        let sent = Sent()
        let push = registrar(sent) { ["ferma-1", "ferma-2"] }
        await push.adopt(token).value
        await push.sync()
        XCTAssertEqual(sent.calls, ["ferma-1 000810", "ferma-2 000810"])
        XCTAssertEqual(push.registered, ["ferma-1", "ferma-2"])
    }

    /// No token yet — iOS has not answered — means nothing to send.
    func testNothingIsSentBeforeIOSHandsOverAToken() async {
        let sent = Sent()
        let push = registrar(sent) { ["ferma-1"] }
        await push.sync()
        XCTAssertEqual(sent.calls, [])
    }

    /// A farm whose registration failed is tried again on the next sync,
    /// and only that farm.
    func testAFailedRegistrationIsSentAgainNextTime() async {
        let sent = Sent()
        sent.refuse = ["ferma-2"]
        let push = registrar(sent) { ["ferma-1", "ferma-2"] }
        await push.adopt(token).value
        XCTAssertEqual(push.registered, ["ferma-1"])

        sent.refuse = []
        sent.calls = []
        await push.sync()
        XCTAssertEqual(sent.calls, ["ferma-2 000810"])
        XCTAssertEqual(push.registered, ["ferma-1", "ferma-2"])
    }

    /// A NEW token is registered with every farm again; the same token
    /// handed over on the next launch is not.
    func testANewTokenIsRegisteredAfresh() async {
        let sent = Sent()
        let push = registrar(sent) { ["ferma-1"] }
        await push.adopt(token).value
        await push.adopt(token).value
        XCTAssertEqual(sent.calls.count, 1, "the same token was sent twice")

        await push.adopt(Data(repeating: 0xff, count: 32)).value
        XCTAssertEqual(sent.calls, ["ferma-1 000810", "ferma-1 ffffff"])
    }

    /// Изход forgets the farms but keeps the token, which is the phone's:
    /// the next person registers it with their own farms.
    func testIzhodForgetsTheFarmsButKeepsTheToken() async {
        let sent = Sent()
        let push = registrar(sent) { sent.farms }
        await push.adopt(token).value

        push.reset()
        XCTAssertEqual(push.registered, [])
        XCTAssertEqual(push.deviceToken, hex)

        sent.farms = ["ferma-9"]
        await push.sync()
        XCTAssertEqual(sent.calls, ["ferma-1 000810", "ferma-9 000810"])
    }

    /// A registration that answers after Изход is not counted for whoever
    /// signs in next — their farms start from nothing.
    func testARegistrationThatLandsAfterIzhodIsNotCounted() async {
        let push = PushRegistrar(
            register: { _, _ in
                // The person signs out while the request is on its way.
                SessionEpoch.advance()
            },
            farms: { ["ferma-1"] }
        )
        await push.adopt(token).value
        XCTAssertEqual(push.registered, [], "a registration from the old session was kept")
    }

    /// A person who signs out while one farm is being registered is not
    /// registered with the rest of their farms afterwards.
    func testIzhodMidwayStopsTheRemainingFarms() async {
        let sent = Sent()
        let push = PushRegistrar(
            register: { _, farm in
                sent.calls.append(farm)
                SessionEpoch.advance()
            },
            farms: { ["ferma-1", "ferma-2", "ferma-3"] }
        )
        await push.adopt(token).value
        XCTAssertEqual(sent.calls, ["ferma-1"], "the old session's farms went on being registered")
    }

    /// A new token that arrives while the old one is being registered is
    /// registered too — the old one's marker does not stand in for it.
    func testANewTokenIsNotSkippedForAnOldOneInFlight() async {
        final class Late { var push: PushRegistrar? }
        let sent = Sent(), late = Late()
        let fresh = Data(repeating: 0xff, count: 32)
        let push = PushRegistrar(
            register: { token, _ in
                sent.calls.append(String(token.prefix(6)))
                // iOS hands over a new token while the first is on its way.
                if sent.calls.count == 1 { await late.push?.adopt(fresh).value }
            },
            farms: { ["ferma-1"] }
        )
        late.push = push
        await push.adopt(token).value
        XCTAssertEqual(sent.calls, ["000810", "ffffff"])
        XCTAssertEqual(push.registered, ["ferma-1"])
    }

    /// This suite runs on a simulator, which is exactly where nothing may be
    /// registered: it would write real rows from a development machine.
    func testNothingRegistersFromASimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(PushRegistrar.mayRegister)
        #else
        XCTAssertTrue(PushRegistrar.mayRegister, "positive control: a device does register")
        #endif
    }

    // MARK: - Изход

    /// The farewell names every farm — registered, on its way, or merely
    /// known — and the bearer its removals need.
    func testTheFarewellNamesEveryFarmAndTheBearer() async {
        let sent = Sent()
        sent.refuse = ["ferma-2"]
        let push = registrar(sent) { ["ferma-2", "ferma-1"] }
        XCTAssertNil(push.farewell(accessToken: "access-A"), "no token, nothing to remove")

        await push.adopt(token).value
        XCTAssertEqual(push.farewell(accessToken: "access-A"),
                       PushFarewell(deviceToken: hex, farms: ["ferma-1", "ferma-2"], accessToken: "access-A"),
                       "a farm whose registration failed may still have a row from an earlier launch")
        XCTAssertNil(push.farewell(accessToken: nil), "no bearer, nothing can be removed")
        XCTAssertNil(push.farewell(accessToken: ""))
    }

    /// The removals go BEFORE the revoke, and the revoke waits for them: a
    /// revoked session's access token is refused at once, so the other
    /// order would answer every removal 401.
    func testTheRemovalsGoBeforeTheRevoke() async {
        final class Order: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func add(_ line: String) { lock.withLock { lines.append(line) } }
            var all: [String] { lock.withLock { lines } }
        }
        let order = Order()
        let farewell = PushFarewell(deviceToken: hex, farms: ["ferma-1", "ferma-2"], accessToken: "access-A")
        let task = SessionRevocation.revokeThisDevice(refreshToken: "rt-A", unregistering: farewell) { req in
            // The removals are slow and the revoke is not; order must hold anyway.
            if req.httpMethod == "DELETE" { try await Task.sleep(for: .milliseconds(50)) }
            order.add("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            return 200
        }
        await task?.value
        XCTAssertEqual(order.all.count, 3)
        XCTAssertEqual(Set(order.all.prefix(2)), ["DELETE /api/t/ferma-1/push-subscriptions",
                                                 "DELETE /api/t/ferma-2/push-subscriptions"])
        XCTAssertEqual(order.all.last, "POST /api/auth/native/revoke")
    }

    /// A removal that fails offline does not stop the revoke.
    func testAFailedRemovalStillRevokes() async {
        final class Revoked: @unchecked Sendable { var yes = false }
        let revoked = Revoked()
        let farewell = PushFarewell(deviceToken: hex, farms: ["ferma-1"], accessToken: "access-A")
        let task = SessionRevocation.revokeThisDevice(refreshToken: "rt-A", unregistering: farewell) { req in
            if req.httpMethod == "DELETE" { throw URLError(.notConnectedToInternet) }
            revoked.yes = true
            return 200
        }
        await task?.value
        XCTAssertTrue(revoked.yes)
    }
}
