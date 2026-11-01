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

    /// The device location is read for the farm's maps and NEVER leaves the
    /// phone (#492, owner 2026-11-01), which is why nothing is declared for
    /// it. Two halves: only the map files may read it, so the surface stays
    /// small enough to review; and none of them has a way out (a request, a
    /// cache, a log, a store on disk). Searched by the calls that read it,
    /// not by `import CoreLocation`: MapKit brings those types in without
    /// the import.
    func testTheDeviceLocationNeverLeavesThePhone() throws {
        let readers = ["CLLocationManager", "UserAnnotation(", "MapUserLocationButton", "showsUserLocation",
                       "DeviceLocation", "StandingIn"]
        // The core, which holds the position: no way out of any kind.
        let core: Set = ["DeviceLocation.swift", "StandingIn.swift", "MapLocationButton.swift"]
        // The maps that draw it or name the parcel under it.
        let maps: Set = ["SatelliteParcelMap.swift", "ParcelMapView.swift", "MechanisatorHomeView.swift",
                         "TaskParcelMap.swift", "TreatmentParcelMap.swift", "TreatmentPlaceView.swift"]
        let ways = ["APIClient", "URLRequest", "URLSession", "ResponseCache", "UserDefaults", "Log.",
                    "FileManager", "PendingOperations", "Outbox", "print("]

        let sources = try XCTUnwrap(FileManager.default.enumerator(
            at: Self.root.appendingPathComponent("Agrent"), includingPropertiesForKeys: nil))
        var files = 0
        var readersSeen: Set<String> = []
        for case let url as URL in sources where url.pathExtension == "swift" {
            files += 1
            let name = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            let reads = readers.filter { text.contains($0) }
            guard !reads.isEmpty else { continue }
            readersSeen.insert(name)
            XCTAssertTrue(core.contains(name) || maps.contains(name),
                          "\(name) reads the device's location (\(reads)); only the maps may, and only to draw it")
            for way in ways + (core.contains(name) ? ["AppStorage"] : []) {
                XCTAssertFalse(text.contains(way), "\(name) holds the position and has a way out: \(way)")
            }
        }
        XCTAssertGreaterThan(files, 50, "positive control: the sources were found")
        XCTAssertTrue(readersSeen.isSuperset(of: core), "positive control: the location's own files moved")

        // Not collected, so not declared: App Store Connect has no Location
        // entry either.
        let declared = try collectedTypes()
        XCTAssertFalse(declared.contains { $0.contains("Location") }, "a declared location means it now leaves the phone")
        XCTAssertTrue(try read("project.yml").contains("NSLocationWhenInUseUsageDescription: Местоположението"),
                      "the system's question needs the Bulgarian reason")
        XCTAssertFalse(try read("project.yml").contains("NSLocationAlwaysAndWhenInUseUsageDescription"),
                       "When In Use only: never in the background")
    }
}
