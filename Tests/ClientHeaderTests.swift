import XCTest
@testable import Agrent

/// The two headers on every request (`ClientHeader`).
///
/// `X-Agrent-Client` — the grammar is the server's (agri-saas P0.5):
/// `<platform>/<major>.<minor>`, 1–3 digits each, ≤ 32 bytes, ASCII.
///
/// `x-agrent-client-version` — the contract this build was written against,
/// which the server's version gate reads (agrent-ios#169).
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

    /// Not `ios/0.0`: that parses, so the server would count it as a real
    /// version. No header is bucketed as `unknown`, which is the truth.
    func testAVersionOutsideTheGrammarSendsNoHeader() {
        for bad in [nil, "", "1.0+481", "1.x", "1234.0", "1.2345", "٣.١", " 1.0", "1..0"] {
            XCTAssertNil(ClientHeader.make(shortVersion: bad), "\(bad ?? "nil")")
        }
    }

    func testEveryProducedValueMatchesTheServersGrammar() {
        for v in ["0.1.0", "1", "1.12", "999.999", "2.3.4"] {
            let header = ClientHeader.make(shortVersion: v)
            XCTAssertTrue(header.map(matchesGrammar) ?? false, "\(v) → \(header ?? "nil")")
        }
        let running = try? XCTUnwrap(ClientHeader.value, "this build's version must be readable")
        XCTAssertTrue(running.map(matchesGrammar) ?? false, "the running bundle's value: \(running ?? "nil")")
        // Negative control: the checker does reject what the server rejects.
        for wrong in ["iOS/1.0", "ios/1.0.3", "ios/1.0+481", "ios/1"] {
            XCTAssertFalse(matchesGrammar(wrong), wrong)
        }
    }

    // MARK: - The stamp

    /// BOTH headers, from the one call every request makes. The names and
    /// the contract are spelt out here rather than read back from
    /// `ClientHeader`, so a constant changed by accident fails this instead
    /// of carrying the test along with it.
    func testStampSetsBothHeaders() throws {
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/x")))
        ClientHeader.stamp(&req)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-agrent-client-version"), "1")
        let client = try XCTUnwrap(req.value(forHTTPHeaderField: "X-Agrent-Client"),
                                   "positive control: this build's version is readable")
        XCTAssertEqual(client, ClientHeader.value, "the counter's value changed on its way out")
        XCTAssertEqual(req.allHTTPHeaderFields?.count, 2, "the stamp sets a header nobody listed")
    }

    /// The two are INDEPENDENT. A version outside the grammar sends no
    /// `X-Agrent-Client`, exactly as before #169, and still declares the
    /// contract: a build with a malformed version string is still one the
    /// gate must be able to retire.
    func testAnUnreadableVersionStillDeclaresTheContract() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/x"))
        var unreadable = URLRequest(url: url)
        ClientHeader.stamp(&unreadable, client: ClientHeader.make(shortVersion: "1.x"))
        XCTAssertNil(unreadable.value(forHTTPHeaderField: "X-Agrent-Client"),
                     "an unreadable version is sent as no header, not as a guess")
        XCTAssertEqual(unreadable.value(forHTTPHeaderField: "x-agrent-client-version"), "1",
                       "an unreadable version hid the build from the version gate")

        // Positive control: a readable one goes out exactly as computed.
        var readable = URLRequest(url: url)
        ClientHeader.stamp(&readable, client: ClientHeader.make(shortVersion: "2.3.4"))
        XCTAssertEqual(readable.value(forHTTPHeaderField: "X-Agrent-Client"), "ios/2.3")
        XCTAssertEqual(readable.value(forHTTPHeaderField: "x-agrent-client-version"), "1")
    }

    /// THE CONTRACT. 1 is agri-saas's `x-api-version` at main 261463d
    /// (2026-10-07), and the header is the spec's `x-client-version-header`.
    ///
    /// Pinned so that changing it is a decision someone makes: raise it only
    /// in the release that decodes the newer contract, never on its own
    /// (ROADMAP, «Decisions locked» 7), and change this test in that release.
    func testTheDeclaredContractIsTheOneThisBuildReads() {
        XCTAssertEqual(ClientHeader.contractVersion, 1,
                       "raised outside a release that understands the newer contract? "
                       + "ROADMAP, «Decisions locked» 7")
        XCTAssertEqual(ClientHeader.contractVersionHeader, "x-agrent-client-version")
    }

    // MARK: - Every request

    /// One place a request is built, and whether that very request is stamped.
    struct RequestSite: Equatable {
        let line: Int
        let stamped: Bool
    }

    /// Every `URLRequest(` in `source` outside a comment line, read WHOLE:
    /// from the constructor to its own closing parenthesis, however many
    /// lines that takes.
    ///
    /// Stamped means `ClientHeader.stamp(&<the name it was assigned to>)`,
    /// that call exactly — not another request's, and not with a value of its
    /// own — within three lines of that parenthesis. A request built inline,
    /// as an argument, has no name to stamp, and is reported.
    static func requestSites(in source: String) -> [RequestSite] {
        let lines = source.components(separatedBy: "\n")
        var sites: [RequestSite] = []
        for (i, line) in lines.enumerated()
        where line.contains("URLRequest(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let name = line.range(of: #"[A-Za-z_][A-Za-z0-9_]*\s*(:\s*URLRequest\s*)?=\s*URLRequest\("#,
                                  options: .regularExpression)
                .map { match in String(line[match].prefix { $0.isLetter || $0.isNumber || $0 == "_" }) }
            // Where the constructor's own parenthesis closes.
            var depth = 0, end = i
            closing: for j in i..<lines.count {
                var text = Substring(lines[j])
                if j == i, let open = text.range(of: "URLRequest(") { text = text[open.lowerBound...] }
                for character in text {
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        depth -= 1
                        if depth == 0 { end = j; break closing }
                    }
                }
            }
            let after = lines[(end + 1)..<min(end + 4, lines.count)]
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let stamped = name.map { name in
                after.contains { $0.hasPrefix("ClientHeader.stamp(&\(name))") }
            } ?? false
            sites.append(RequestSite(line: i + 1, stamped: stamped))
        }
        return sites
    }

    /// EVERY request the app builds is stamped as it is built, and so carries
    /// both headers: the counter's and the version gate's. A request built
    /// without the stamp fails here, naming its file and line.
    ///
    /// Six today: `APIClient.request(for:…)`, which every API call goes
    /// through, the token refresh, the native exchange, the revoke, the
    /// third-party picture and the index tiles. The tiles' request went out
    /// UNSTAMPED from #144 to #169, past this test's first scan, which matched
    /// `URLRequest(url:` on one line — and that constructor spans five.
    func testEveryRequestTheAppBuildsIsStamped() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sites = 0, unstamped: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let found = Self.requestSites(in: try String(contentsOf: url, encoding: .utf8))
            sites += found.count
            unstamped += found.filter { !$0.stamped }.map { "\(url.lastPathComponent):\($0.line)" }
        }
        XCTAssertGreaterThanOrEqual(sites, 6, "positive control: the scan stopped finding requests")
        XCTAssertTrue(unstamped.isEmpty,
                      "requests without X-Agrent-Client and x-agrent-client-version: \(unstamped)")
    }

    /// The scan itself, on requests written to get past it: the two shapes
    /// it must pass, and each one it must catch.
    func testTheScanReadsARequestWhole() {
        let oneLine = "var req = URLRequest(url: u)\nClientHeader.stamp(&req)"
        let fiveLines = """
            var request = URLRequest(
                url: url(forTilePath: path),
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            ClientHeader.stamp(&request)
            """
        XCTAssertEqual(Self.requestSites(in: oneLine), [RequestSite(line: 1, stamped: true)])
        XCTAssertEqual(Self.requestSites(in: fiveLines), [RequestSite(line: 1, stamped: true)])

        let unstamped: [(shape: String, source: String)] = [
            ("the tiles' request before #169",
             "let request = URLRequest(\n    url: u,\n    timeoutInterval: 15\n)\nsession.dataTask(with: request)"),
            ("another request stamped", "var req = URLRequest(url: u)\nClientHeader.stamp(&other)"),
            ("built inline, with no name to stamp", "session.data(for: URLRequest(url: u))"),
            ("a value of its own", "var req = URLRequest(url: u)\nClientHeader.stamp(&req, client: \"ios/9.9\")"),
            ("stamped too late", "var req = URLRequest(url: u)\na()\nb()\nc()\nClientHeader.stamp(&req)"),
        ]
        for (shape, source) in unstamped {
            XCTAssertEqual(Self.requestSites(in: source).map(\.stamped), [false], shape)
        }
        XCTAssertTrue(Self.requestSites(in: "// var req = URLRequest(url: u)\n/// see `URLRequest(`").isEmpty,
                      "a comment is not a request")
    }
}
