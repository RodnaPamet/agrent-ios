import CryptoKit
import XCTest
@testable import Agrent

/// `Agrent/Design/Generated/Tokens.swift` is GENERATED in agri-saas and
/// vendored by `scripts/sync-design-tokens.sh`. A hand edit here would make
/// the app's colours diverge from the web's while both still claim to come
/// from tokens.json, so the body is hashed against what the script recorded.
///
/// The Guards job runs `scripts/sync-design-tokens.sh --check` for the same
/// property; this is the copy that runs in `scripts/check.sh`.
final class VendoredTokensTests: XCTestCase {
    /// The script's `HEADER_LINES`. Change both together.
    private static let headerLines = 6

    private static func vendored() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Agrent/Design/Generated/Tokens.swift"),
                          encoding: .utf8)
    }

    /// The header's recorded hash, and the hash the body has now.
    private static func hashes(of file: String) throws -> (recorded: String, actual: String) {
        let lines = file.components(separatedBy: "\n")
        let prefix = "// sha256 of the body: "
        let recorded = try XCTUnwrap(lines.prefix(headerLines).first { $0.hasPrefix(prefix) })
            .dropFirst(prefix.count)
        let body = lines.dropFirst(headerLines).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        return (String(recorded), digest)
    }

    func testTheVendoredTokensAreExactlyWhatWasVendored() throws {
        let file = try Self.vendored()
        XCTAssertTrue(file.contains("// Source: RodnaPamet/agri-saas@"), "the header names no source commit")
        let (recorded, actual) = try Self.hashes(of: file)
        XCTAssertEqual(actual, recorded, """
            Tokens.swift was edited after it was vendored. It is generated from agri-saas \
            design/tokens.json — change the value there and re-run scripts/sync-design-tokens.sh.
            """)
    }

    /// Positive control: the same check on a body with one byte changed
    /// must fail, or the test above proves nothing.
    func testAOneByteEditIsCaught() throws {
        let file = try Self.vendored()
        let edited = file.replacingOccurrences(of: "case .dark: return Color(red: 0.0196",
                                               with: "case .dark: return Color(red: 0.0197")
        XCTAssertNotEqual(edited, file, "the control's edit did not apply — pick another anchor")
        let (recorded, actual) = try Self.hashes(of: edited)
        XCTAssertNotEqual(actual, recorded)
    }
}
