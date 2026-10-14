import UserNotifications
import XCTest
@testable import Agrent

/// The notification ask — the card in «Задачи» and Профил's switch
/// (agrent-ios#272; owner, 2026-10-14). iOS is a seam here: nothing asks the
/// simulator for permission, opens Settings, or reaches a server.
@MainActor
final class PushPermissionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "test.push.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    /// iOS as the tests drive it, and what was asked of it.
    private final class Phone {
        var status: UNAuthorizationStatus = .notDetermined
        /// What the person answers the one prompt with.
        var answer: UNAuthorizationStatus = .authorized
        var asked = 0
        var settingsOpened = 0
        var sent: [String] = []
        /// Who is signed in, changed the way the app changes it.
        let identity = SessionIdentity(load: { "usr_a" }, save: { _ in })
    }

    private func permission(_ phone: Phone) -> (PushPermission, PushRegistrar) {
        let registrar = PushRegistrar(
            register: { _, farm in phone.sent.append("+\(farm)") },
            unregister: { _, farm in phone.sent.append("-\(farm)") },
            farms: { ["ferma-1", "ferma-2"] },
            wanted: { true }
        )
        let permission = PushPermission(
            defaults: defaults,
            identity: phone.identity,
            readStatus: { phone.status },
            ask: {
                phone.asked += 1
                phone.status = phone.answer
            },
            openSettings: { phone.settingsOpened += 1 },
            registrar: { registrar }
        )
        return (permission, registrar)
    }

    private let token = Data(repeating: 0x0a, count: 32)

    // MARK: - The card

    /// The card shows only while iOS can still ask — not before the answer
    /// is read, and not once the person has answered either way.
    func testTheCardShowsOnlyWhileIOSCanStillAsk() async {
        let phone = Phone()
        let (push, _) = permission(phone)
        XCTAssertFalse(push.showsCard, "shown before iOS was asked where it stands")

        await push.refresh()
        XCTAssertTrue(push.showsCard)

        for answered in [UNAuthorizationStatus.authorized, .denied, .provisional] {
            phone.status = answered
            await push.refresh()
            XCTAssertFalse(push.showsCard, "still asking after \(answered.rawValue)")
        }
    }

    /// Closed is closed on this phone, for good: the next launch reads it.
    func testAClosedCardStaysClosed() async {
        let phone = Phone()
        let (push, _) = permission(phone)
        await push.refresh()
        push.closeCard()
        XCTAssertFalse(push.showsCard)

        let (relaunched, _) = permission(phone)
        await relaunched.refresh()
        XCTAssertFalse(relaunched.showsCard, "the card came back after a relaunch")
        XCTAssertEqual(phone.asked, 0, "closing the card asked iOS anyway")
    }

    // MARK: - Turning on

    /// «Включи»: iOS asks once, and a yes registers the phone with every farm.
    func testTurningOnAsksOnceThenRegisters() async {
        let phone = Phone()
        let (push, registrar) = permission(phone)
        await registrar.adopt(token).value
        phone.sent = []   // what the launch registered is not this test's

        await push.refresh()
        registrar.reset()
        await push.turnOn()
        XCTAssertEqual(phone.asked, 1)
        XCTAssertEqual(push.standing, .allowed)
        XCTAssertTrue(push.isOn)
        XCTAssertEqual(phone.sent, ["+ferma-1", "+ferma-2"])
    }

    /// A no at the prompt leaves the switch off, and asking again is not
    /// iOS's to do: the next «on» opens Settings instead.
    func testAfterANoOnlySettingsCanTurnItOn() async {
        let phone = Phone()
        phone.answer = .denied
        let (push, _) = permission(phone)
        await push.refresh()
        await push.turnOn()
        XCTAssertEqual(push.standing, .refused)
        XCTAssertFalse(push.isOn)

        await push.turnOn()
        XCTAssertEqual(phone.asked, 1, "iOS was asked a second time; it would not have shown anything")
        XCTAssertEqual(phone.settingsOpened, 1)
    }

    // MARK: - The person's switch

    /// Off removes this phone from the person's farms and is kept for THAT
    /// person: the next person on the phone starts on.
    func testOffIsThePersonsAndRemovesThePhone() async {
        let phone = Phone()
        phone.status = .authorized
        let (push, registrar) = permission(phone)
        await registrar.adopt(token).value
        await push.refresh()
        XCTAssertTrue(push.isOn)

        phone.sent = []
        await push.turnOff()
        XCTAssertFalse(push.isOn)
        XCTAssertEqual(phone.sent, ["-ferma-1", "-ferma-2"])
        XCTAssertEqual(registrar.registered, [])
        XCTAssertTrue(push.storedSwitchedOff, "the registrar would register again at the next launch")

        // Изход, and someone else signs in on the same phone.
        push.reset()
        phone.identity.clear()
        phone.identity.adopt("usr_b")
        await push.refresh()
        XCTAssertTrue(push.isOn, "the last person's off silenced the next one")

        // And the first person, back, is still off.
        phone.identity.adopt("usr_a")
        await push.refresh()
        XCTAssertFalse(push.isOn)
    }

    /// A person who switched off is not registered again by the launch's
    /// own sync — the registrar asks the stored switch, not the screen.
    func testSwitchedOffStopsTheLaunchRegistration() async {
        let phone = Phone()
        let registrar = PushRegistrar(
            register: { _, farm in phone.sent.append(farm) },
            farms: { ["ferma-1"] },
            wanted: { false }
        )
        await registrar.adopt(token).value
        XCTAssertEqual(phone.sent, [])
    }
}
