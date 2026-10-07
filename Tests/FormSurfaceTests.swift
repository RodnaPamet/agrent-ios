import XCTest

/// Every `Form` in the app is a `PageForm` (agrent-ios#156): the page token
/// behind it, card-token rows. A bare `Form` draws on
/// `systemGroupedBackground` — black in dark mode under a green app — and
/// ten of them did until this. There is no runtime hook that says which
/// background a presented sheet drew, so this reads the source, with a
/// positive control so a moved directory fails rather than passes.
///
/// The same for every `List` (#164): the page behind it and the page under
/// its rows — `testEveryListIsOnThePage`.
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

    // MARK: - Lists (#164)

    /// Every `List` is on the page: `.pageBackground()` in the modifiers
    /// after it, and a row background — `pageRow()`, `cardRow()` or
    /// `listRowBackground` — somewhere in its rows.
    ///
    /// Two checks because a List draws two backgrounds (see
    /// `pageBackground()`). Without the first the system's grouped grey shows
    /// round the rows; without the second each row is a grouped CARD in the
    /// system's colour. Five lists were the first (#164), and checking each
    /// list rather than each file found three more that were the second —
    /// a file with one good list hid them.
    ///
    /// Per LIST, not per file, for that reason. The row content is the
    /// list's trailing closure; a list whose rows come from helpers that set
    /// their own background still says so once in the closure — see
    /// `ParcelHistoryView`.
    func testEveryListIsOnThePage() {
        let sources = appSources()
        var lists = 0
        var offenders: [String] = []
        for (name, text) in sources {
            for (index, list) in Self.lists(in: Self.code(text)).enumerated() {
                lists += 1
                if !list.modifiers.contains(".pageBackground()") {
                    offenders.append("\(name) list \(index + 1): no .pageBackground()")
                }
                if !Self.hasRowBackground(list.rows) {
                    offenders.append("\(name) list \(index + 1): no pageRow() / cardRow() on its rows")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "a List off the page draws the system's grouped grey — black in dark mode under a "
                     + "green app. Add .pageBackground() to the list and .pageRow() to its rows")
        XCTAssertGreaterThanOrEqual(lists, 26, "positive control: the app's lists were found")
    }

    /// Positive control for the list reader.
    func testTheListReaderSeesBothBackgrounds() {
        let bare = Self.lists(in: "List {\n    Text(\"a\")\n}\n.listStyle(.plain)\n")
        XCTAssertEqual(bare.count, 1)
        XCTAssertFalse(bare[0].modifiers.contains(".pageBackground()"))
        XCTAssertEqual(bare[0].rows, "\n    Text(\"a\")\n")

        let page = Self.lists(in: "List(rows) { Row($0).pageRow() }\n    .refreshable { }\n    .pageBackground()\n")
        XCTAssertEqual(page.count, 1)
        XCTAssertTrue(page[0].modifiers.contains(".pageBackground()"))
        XCTAssertTrue(Self.hasRowBackground(page[0].rows))
        XCTAssertFalse(Self.hasRowBackground(bare[0].rows))
        XCTAssertTrue(Self.hasRowBackground("Text(a).listRowBackground(Palette.Surface.card)"))

        // The modifiers stop at the first line that is not one, so a later
        // list's `.pageBackground()` cannot vouch for this one.
        let two = Self.lists(in: "List { a }\n.listStyle(.plain)\nlet x = 1\nList { b.pageRow() }\n.pageBackground()\n")
        XCTAssertEqual(two.map { $0.modifiers.contains(".pageBackground()") }, [false, true])

        XCTAssertEqual(Self.lists(in: "ParcelHistorySectionList(store: s) { }").count, 0)
        XCTAssertEqual(Self.lists(in: "Form { }").count, 0)
    }

    /// A row background, as `pageRow()` / `cardRow()` set it.
    private static func hasRowBackground(_ rows: String) -> Bool {
        rows.range(of: #"\.(pageRow|cardRow)\(\)|\.listRowBackground\("#, options: .regularExpression) != nil
    }

    /// `List {` or `List(…) {` — not `ParcelHistorySectionList(`.
    private static let listOpening = try? NSRegularExpression(pattern: #"(?<![A-Za-z.])List\s*(\{|\()"#)

    /// Source with whole-line comments removed, so a comment that mentions a
    /// `List {` is not read as one.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Each `List` in `code`: its ROWS (the trailing closure's body) and its
    /// MODIFIERS (the rest of the closing line, and every following line
    /// that starts with `.`). Read in UTF-16, the unit `NSRegularExpression`
    /// counts in; the braces it matches are ASCII.
    static func lists(in code: String) -> [(rows: String, modifiers: String)] {
        guard let opening = listOpening else { return [] }
        let units = Array(code.utf16)
        let (brace, closeBrace) = (UInt16(UInt8(ascii: "{")), UInt16(UInt8(ascii: "}")))
        let (paren, closeParen) = (UInt16(UInt8(ascii: "(")), UInt16(UInt8(ascii: ")")))
        let blank: Set<UInt16> = [UInt16(UInt8(ascii: " ")), UInt16(UInt8(ascii: "\t")), UInt16(UInt8(ascii: "\n"))]

        func closing(from start: Int, _ open: UInt16, _ close: UInt16) -> Int? {
            var depth = 0
            for index in start..<units.count {
                if units[index] == open { depth += 1 }
                if units[index] == close {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            return nil
        }
        func text(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }

        return opening.matches(in: code, range: NSRange(location: 0, length: units.count)).compactMap {
            match -> (rows: String, modifiers: String)? in
            var start = match.range.location + match.range.length - 1
            if units[start] == paren {
                // `List(rows) { … }`: past the arguments to the closure.
                guard let end = closing(from: start, paren, closeParen) else { return nil }
                start = end + 1
                while start < units.count, blank.contains(units[start]) { start += 1 }
                guard start < units.count, units[start] == brace else { return ("", "") }
            }
            guard let end = closing(from: start, brace, closeBrace) else { return nil }
            let after = text(end + 1..<units.count).split(separator: "\n", omittingEmptySubsequences: false)
            var modifiers = [String(after.first ?? "")]
            for line in after.dropFirst() {
                guard line.trimmingCharacters(in: .whitespaces).hasPrefix(".") else { break }
                modifiers.append(String(line))
            }
            return (text(start + 1..<end), modifiers.joined(separator: "\n"))
        }
    }
}
