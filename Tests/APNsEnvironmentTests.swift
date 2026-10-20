import XCTest
@testable import Agrent

/// Which APNs host this install's token works against, read from its
/// provisioning profile (#355). The profiles here are synthetic: a property
/// list between bytes that stand in for the signed envelope around it.
final class APNsEnvironmentTests: XCTestCase {
    private func profile(_ root: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        return Data([0x30, 0x82, 0x2F, 0x41, 0x06, 0x09]) + plist + Data([0xA0, 0x82, 0x0D, 0x00])
    }

    private func profile(aps: String) throws -> Data {
        try profile(["Name": "Test profile", "Entitlements": ["aps-environment": aps, "get-task-allow": true]])
    }

    func testADevelopmentProfileIsTheSandbox() throws {
        XCTAssertEqual(APNsEnvironment.of(profile: try profile(aps: "development")), .development)
    }

    /// An ad hoc profile carries one too, and its tokens are production ones.
    func testAProductionProfileIsProduction() throws {
        XCTAssertEqual(APNsEnvironment.of(profile: try profile(aps: "production")), .production)
    }

    /// The App Store strips the profile: TestFlight and App Store installs
    /// have none, and their tokens are production ones.
    func testNoProfileIsProduction() {
        XCTAssertEqual(APNsEnvironment.of(profileAt: nil), .production)
    }

    func testAProfileOnDiskIsRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-\(UUID().uuidString).mobileprovision")
        try profile(aps: "development").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(APNsEnvironment.of(profileAt: url), .development)
    }

    /// A profile that is there but doesn't say is not a guess: the field is
    /// left out, and the server refuses and logs the gap.
    func testAProfileThatDoesntSayIsNoAnswer() throws {
        XCTAssertNil(APNsEnvironment.of(profile: nil), "unreadable")
        XCTAssertNil(APNsEnvironment.of(profile: Data("not a profile".utf8)))
        XCTAssertNil(APNsEnvironment.of(profile: try profile(["Name": "Test profile"])), "no entitlements")
        XCTAssertNil(APNsEnvironment.of(profile: try profile(["Entitlements": ["get-task-allow": true]])),
                     "no push entitlement")
        XCTAssertNil(APNsEnvironment.of(profile: try profile(aps: "sandbox")), "a word that isn't a host")
        let whole = try profile(aps: "development")
        XCTAssertNil(APNsEnvironment.of(profile: whole.prefix(whole.count - 20)), "cut short")
    }

    /// The missing profile's answer is production; a missing FILE behind a
    /// URL is unreadable, not missing.
    func testAProfileThatCantBeOpenedIsNoAnswer() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        XCTAssertNil(APNsEnvironment.of(profileAt: url))
    }
}
