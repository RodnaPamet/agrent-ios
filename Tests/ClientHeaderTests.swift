import XCTest
@testable import Agrent

/// `X-Agrent-Client` — the grammar is the server's (agri-saas P0.5):
/// `<platform>/<major>.<minor>`, 1–3 digits each, ≤ 32 bytes, ASCII.
final class ClientHeaderTests: XCTestCase {

    /// The literal grammar, as the server will parse it.
    private func matchesGrammar(_ v: String) -> Bool {
        v.utf8.count <= 32
            && v.range(of: #"^(ios|android|web)/[0-9]{1,3}\.[0-9]{1,3}$"#,
                       options: .regularExpression) != nil
    }

    func testMajorMinorOnly() {
        XCTAssertEqual(ClientHeader.make(shortVersion: "0.1.0"), "ios/0.1")
        XCTAssertEqual(ClientHeader.make(shortVersion: "1.12"), "ios/1.12")
        XCTAssertEqual(ClientHeader.make(shortVersion: "2.3.4"), "ios/2.3", "no patch")
        XCTAssertEqual(ClientHeader.make(shortVersion: "1"), "ios/1.0",
                       "a one-component version is major.0, not `ios/1`")
    }

    func testAVersionOutsideTheGrammarIsSentAsZeroNotDropped() {
        for bad in [nil, "", "1.0+481", "1.x", "1234.0", "1.2345", "٣.١", " 1.0", "1..0"] {
            XCTAssertEqual(ClientHeader.make(shortVersion: bad), "ios/0.0", "\(bad ?? "nil")")
        }
    }

    func testEveryProducedValueMatchesTheServersGrammar() {
        for v in ["0.1.0", "1", "1.12", "999.999", "2.3.4", "garbage", nil] {
            let header = ClientHeader.make(shortVersion: v)
            XCTAssertTrue(matchesGrammar(header), header)
        }
        XCTAssertTrue(matchesGrammar(ClientHeader.value), "the running bundle's value: \(ClientHeader.value)")
        // Negative control: the checker does reject what the server rejects.
        for wrong in ["iOS/1.0", "ios/1.0.3", "ios/1.0+481", "ios/1"] {
            XCTAssertFalse(matchesGrammar(wrong), wrong)
        }
    }

    func testStampSetsTheHeader() throws {
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/x")))
        ClientHeader.stamp(&req)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Agrent-Client"), ClientHeader.value)
    }

    /// EVERY request: each `URLRequest(url:` in the app is followed by a
    /// stamp. A fifth request built without one fails here, naming the file.
    func testEveryRequestTheAppBuildsIsStamped() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sites = 0, unstamped: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated()
            where line.contains("URLRequest(url:") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                sites += 1
                let next = lines[(i + 1)..<min(i + 4, lines.count)].joined(separator: "\n")
                if !next.contains("ClientHeader.stamp(&req)") {
                    unstamped.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(sites, 4, "positive control: the scan stopped finding requests")
        XCTAssertTrue(unstamped.isEmpty, "requests without X-Agrent-Client: \(unstamped)")
    }
}
