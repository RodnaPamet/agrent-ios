import XCTest

/// `PrivacyInfo.xcprivacy` declares what leaves the phone, and App Store
/// Connect's "App Privacy" answers must agree with it. Nothing checks either
/// against the code, so each declared type here is tied to the code that
/// sends it: removing the code's reason should be a deliberate edit to this
/// file too, and adding a new kind of data should fail review here first.
final class PrivacyManifestTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func collectedTypes() throws -> [String] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Agrent/Resources/PrivacyInfo.xcprivacy"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let entries = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        for entry in entries {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false,
                           "\(entry["NSPrivacyCollectedDataType"] ?? "?") is declared as tracking")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        }
        return entries.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
    }

    func testEveryKindOfDataThatLeavesThePhoneIsDeclared() throws {
        let declared = try collectedTypes()
        XCTAssertEqual(declared.sorted(), [
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypePhotosorVideos",
            "NSPrivacyCollectedDataTypeUserID",
        ], "a change here needs the same change in App Store Connect's App Privacy answers")
    }

    /// The reasons, read from the code: Sign in with Apple asks for the
    /// email, and Профил uploads a photo.
    func testEachDeclaredTypeHasItsReasonInTheCode() throws {
        let declared = try collectedTypes()
        let auth = try read("Agrent/Auth/AuthClient.swift")
        XCTAssertTrue(auth.contains("requestedScopes = [.email]"), "positive control: the email scope moved")
        XCTAssertTrue(declared.contains("NSPrivacyCollectedDataTypeEmailAddress"))

        let picture = try read("Agrent/Account/AccountPicture.swift")
        XCTAssertTrue(picture.contains("postMultipart"), "positive control: the picture upload moved")
        XCTAssertTrue(declared.contains("NSPrivacyCollectedDataTypePhotosorVideos"))
    }

    /// No device location: nothing asks for it, so nothing to declare. A
    /// first use must come with a manifest entry. Searched by the calls
    /// that read it, not by `import CoreLocation`: MapKit brings those
    /// types in without the import.
    func testNoDeviceLocationIsRead() throws {
        let readers = ["CLLocationManager", "UserAnnotation(", "MapUserLocationButton", "showsUserLocation"]
        let sources = try XCTUnwrap(FileManager.default.enumerator(
            at: Self.root.appendingPathComponent("Agrent"), includingPropertiesForKeys: nil))
        var files = 0
        for case let url as URL in sources where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for reader in readers {
                XCTAssertFalse(text.contains(reader), "\(url.lastPathComponent) reads the device's location (\(reader))")
            }
        }
        XCTAssertGreaterThan(files, 50, "positive control: the sources were found")
    }
}
