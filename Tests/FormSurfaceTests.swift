import XCTest

/// Every `Form` in the app is a `PageForm` (agrent-ios#156): the page token
/// behind it, card-token rows. A bare `Form` draws on
/// `systemGroupedBackground` — black in dark mode under a green app — and
/// ten of them did until this. There is no runtime hook that says which
/// background a presented sheet drew, so this reads the source, with a
/// positive control so a moved directory fails rather than passes.
final class FormSurfaceTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func appSources() -> [(String, String)] {
        let app = Self.root.appendingPathComponent("Agrent")
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.lastPathComponent, text))
        }
        return out
    }

    /// `Form {` not preceded by a letter — so `PageForm {` does not match.
    private static let bareForm = try? NSRegularExpression(pattern: #"(?<![A-Za-z])Form\s*\{"#)

    /// Lines opening a bare `Form`, comment lines skipped.
    private func bareForms(in text: String) -> Int {
        guard let matcher = Self.bareForm else { return -1 }
        return text.split(separator: "\n").filter { line in
            let code = String(line)
            guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return false }
            return matcher.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }.count
    }

    func testEveryFormIsAPageForm() {
        let sources = appSources()
        XCTAssertGreaterThan(sources.count, 50, "positive control: the app's sources were found")
        // The one bare `Form` is the one inside `PageForm` itself.
        let offenders = sources.filter { bareForms(in: $0.1) != 0 }.map(\.0)
        XCTAssertEqual(offenders, ["PageBackground.swift"],
                       "a bare Form draws the system's grouped grey — use PageForm")
        let pageForms = sources.map { $0.1.components(separatedBy: "PageForm {").count - 1 }.reduce(0, +)
        XCTAssertGreaterThanOrEqual(pageForms, 10, "the ten forms of #156")
    }

    /// Positive control for the matcher itself.
    func testTheMatcherSeesABareFormAndNotAPageForm() {
        XCTAssertEqual(bareForms(in: "        Form {\n"), 1)
        XCTAssertEqual(bareForms(in: "        PageForm {\n"), 0)
        XCTAssertEqual(bareForms(in: "        // a Form { in a comment\n"), 0)
    }
}
