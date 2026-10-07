import XCTest

/// The text a `List` or `Form` draws around its rows goes through
/// `Design/FormChrome.swift` (agrent-ios#159, #160), never through the
/// system's own greys or its menu picker:
///
///   - a section's title is `Section(titled:)`, and a `header:` / `footer:`
///     closure opens with `SectionHeader` / `SectionFooter` — the system
///     draws a bare one in `secondaryLabel`, 3.29:1 on the light page;
///   - every `TextField` has a `prompt: .fieldPrompt(…)` — without one the
///     title is drawn in `placeholderText`, about 1.9:1 on the light card;
///   - `LabeledContent` is written only inside `FormChrome.swift`, as
///     `ValueRow` / `FieldRow` / `MenuPicker` — its default value grey is
///     3.34:1 on the light card;
///   - every `Picker` names its style — a bare one in a `Form` is the menu
///     picker whose UIKit-drawn value cut «Дейност» to «Де…ст»;
///   - and the style is never `.navigationLink`, whose pushed page is a
///     List the system draws on its grouped grey (#164);
///   - every `DatePicker` is tinted `Palette.DatePill.tint`, measured on
///     the system's pill (#164).
///
/// There is no runtime hook that says what colour the system drew a header
/// in, so this reads the source, as `FormSurfaceTests` does, with a positive
/// control for every matcher.
final class ListChromeTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    /// (file name, source with whole-line comments removed).
    private func appSources() -> [(String, String)] {
        let app = Self.root.appendingPathComponent("Agrent")
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.lastPathComponent, Self.code(text)))
        }
        return out
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - Matchers

    /// `Section(…)` with a title the system styles. `titled:` is the house
    /// one; `items:` is `ParcelHistoryStore.Section`, a different type.
    private static let systemSection = #"(?<![A-Za-z.])Section\((?!titled:|items:)"#

    /// A header or footer closure that does not open with the house view.
    private static let bareChrome = #"\}\s*(header|footer):\s*\{(?!\s*Section(Header|Footer)\b)"#

    private static let labeledContent = #"(?<![A-Za-z])LabeledContent\b"#
    private static let picker = #"(?<![A-Za-z])Picker\("#
    private static let pickerStyle = #"\.pickerStyle\("#
    private static let pushedPicker = #"\.pickerStyle\(\s*\.navigationLink\s*\)"#
    private static let datePicker = #"(?<![A-Za-z])DatePicker\("#
    private static let datePillTint = #"\.tint\(Palette\.DatePill\.tint\)"#

    /// `TextField(` calls whose argument list carries no styled prompt.
    private static func unpromptedFields(in text: String) -> Int {
        var misses = 0
        var search = text.startIndex
        while let open = text.range(of: "TextField(", range: search..<text.endIndex) {
            // `TextField(` preceded by a letter is another name.
            if open.lowerBound > text.startIndex,
               text[text.index(before: open.lowerBound)].isLetter {
                search = open.upperBound
                continue
            }
            var depth = 1
            var index = open.upperBound
            while depth > 0, index < text.endIndex {
                switch text[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                index = text.index(after: index)
            }
            if !text[open.upperBound..<index].contains("prompt: .fieldPrompt(") { misses += 1 }
            search = index
        }
        return misses
    }

    // MARK: - The app

    func testSectionTitlesAreTheHouseOnes() {
        let sources = appSources()
        XCTAssertGreaterThan(sources.count, 50, "positive control: the app's sources were found")
        let offenders = sources.filter {
            Self.count(Self.systemSection, in: $0.1) + Self.count(Self.bareChrome, in: $0.1) != 0
        }.map(\.0)
        XCTAssertEqual(offenders, [],
                       "a bare section title is drawn in secondaryLabel (3.29:1 on the light page) — "
                     + "use Section(titled:), SectionHeader or SectionFooter")
        let house = sources.map { Self.count(#"Section\(titled:|Section(Header|Footer)\b"#, in: $0.1) }
            .reduce(0, +)
        XCTAssertGreaterThanOrEqual(house, 60, "the ~60 headers and footers of #159")
    }

    func testEveryTextFieldHasAStyledPrompt() {
        let sources = appSources()
        let offenders = sources.filter { $0.0 != "FormChrome.swift" && Self.unpromptedFields(in: $0.1) != 0 }
            .map(\.0)
        XCTAssertEqual(offenders, [],
                       "a TextField without a prompt shows its title in placeholderText (~1.9:1) — "
                     + "add prompt: .fieldPrompt(…)")
        let fields = sources.map { $0.1.components(separatedBy: "prompt: .fieldPrompt(").count - 1 }
            .reduce(0, +)
        XCTAssertGreaterThanOrEqual(fields, 24, "the 23 form fields of #159 and the composer")
    }

    func testLabeledContentIsOnlyInFormChrome() {
        let offenders = appSources().filter { Self.count(Self.labeledContent, in: $0.1) != 0 }.map(\.0)
        XCTAssertEqual(offenders, ["FormChrome.swift"],
                       "LabeledContent draws its value in secondaryLabel (3.34:1 on the light card) — "
                     + "use ValueRow, FieldRow or MenuPicker")
    }

    func testEveryPickerNamesItsStyle() {
        let sources = appSources()
        let offenders = sources.filter {
            Self.count(Self.picker, in: $0.1) > Self.count(Self.pickerStyle, in: $0.1)
        }.map(\.0)
        XCTAssertEqual(offenders, [],
                       "a Picker with no style is a menu picker in a Form, whose UIKit-drawn value "
                     + "cut «Дейност» to «Де…ст» (#160) — use MenuPicker or name a style")
        XCTAssertGreaterThanOrEqual(sources.map { Self.count(#"MenuPicker\("#, in: $0.1) }.reduce(0, +), 13,
                                    "the menu pickers of #160, its siblings, and the four of #164")
    }

    /// No picker pushes the system's page. `.pickerStyle(.navigationLink)`
    /// pushes a List the system builds, on `systemGroupedBackground`, which
    /// nothing in the app can reach to paint (#164) — a short list of
    /// options is a `MenuPicker`, a long one a `PagePicker`.
    func testNoPickerPushesASystemPage() {
        let sources = appSources()
        let offenders = sources.filter { Self.count(Self.pushedPicker, in: $0.1) != 0 }.map(\.0)
        XCTAssertEqual(offenders, [],
                       "a .navigationLink picker pushes a page on the system's grouped grey — "
                     + "use MenuPicker for a short list or PagePicker for a long one")
        XCTAssertGreaterThanOrEqual(sources.map { Self.count(#"PagePicker\("#, in: $0.1) }.reduce(0, +), 2,
                                    "«Парцел» and «Покритие» on the insurance form")
    }

    /// Every `DatePicker` carries `Palette.DatePill.tint`: the app's tint is
    /// 4.43:1 on the pill in light while the calendar is open (#164).
    func testEveryDatePickerIsTintedForItsPill() {
        let sources = appSources()
        let offenders = sources.filter {
            Self.count(Self.datePicker, in: $0.1) > Self.count(Self.datePillTint, in: $0.1)
        }.map(\.0)
        XCTAssertEqual(offenders, [],
                       "a DatePicker in the app's tint draws its open date at 4.43:1 on its pill in light — "
                     + "add .tint(Palette.DatePill.tint)")
        XCTAssertGreaterThanOrEqual(sources.map { Self.count(Self.datePicker, in: $0.1) }.reduce(0, +), 3,
                                    "positive control: «Дата» twice and «Валидна до»")
    }

    // MARK: - Positive controls

    func testTheSectionMatchersSeeTheSystemOnesAndNotTheHouseOnes() {
        XCTAssertEqual(Self.count(Self.systemSection, in: #"Section("Регион") {"#), 1)
        XCTAssertEqual(Self.count(Self.systemSection, in: "Section(header: Text(\"a\"), footer: b) {"), 1)
        XCTAssertEqual(Self.count(Self.systemSection, in: #"Section(titled: "Регион") {"#), 0)
        XCTAssertEqual(Self.count(Self.systemSection, in: "seasons = Section(items: a, cursor: b)"), 0)
        XCTAssertEqual(Self.count(Self.systemSection, in: "Section {"), 0)

        XCTAssertEqual(Self.count(Self.bareChrome, in: "} header: {\n    Text(\"Файл\")\n}"), 1)
        XCTAssertEqual(Self.count(Self.bareChrome, in: "} footer: {\n    if a { Text(\"b\") }\n}"), 1)
        XCTAssertEqual(Self.count(Self.bareChrome, in: "} header: {\n    SectionHeader(\"Файл\")\n}"), 0)
        XCTAssertEqual(Self.count(Self.bareChrome, in: "} footer: { SectionFooter { x } }"), 0)
    }

    func testTheFieldMatcherSeesAMissingPrompt() {
        XCTAssertEqual(Self.unpromptedFields(in: #"TextField("Сума", text: $amount)"#), 1)
        XCTAssertEqual(Self.unpromptedFields(in: #"TextField("a", text: $b, prompt: Text("—"))"#), 1)
        XCTAssertEqual(Self.unpromptedFields(in: "TextField(f(x), text: binding(field),\n"
                                                + "  prompt: .fieldPrompt(\"—\"), axis: .vertical)"), 0)
        XCTAssertEqual(Self.unpromptedFields(in: #"MyTextField("a")"#), 0)
    }

    func testThePickerMatchersCountOnlyPickers() {
        XCTAssertEqual(Self.count(Self.picker, in: #"Picker("Тип", selection: $t) {"#), 1)
        XCTAssertEqual(Self.count(Self.picker, in: #"DatePicker("Дата", selection: $d)"#), 0)
        XCTAssertEqual(Self.count(Self.picker, in: #"MenuPicker("Тип", selection: $t, value: v) {"#), 0)
        XCTAssertEqual(Self.count(Self.labeledContent, in: "ValueRow(\"a\") { b }"), 0)
        XCTAssertEqual(Self.count(Self.labeledContent, in: "LabeledContent {"), 1)
        XCTAssertEqual(Self.count(Self.pushedPicker, in: ".pickerStyle(.navigationLink)"), 1)
        XCTAssertEqual(Self.count(Self.pushedPicker, in: ".pickerStyle(.inline)"), 0)
        XCTAssertEqual(Self.count(Self.datePicker, in: #"DatePicker("Дата", selection: $d)"#), 1)
        XCTAssertEqual(Self.count(Self.datePicker, in: "struct MyDatePicker("), 0)
        XCTAssertEqual(Self.count(Self.datePillTint, in: ".tint(Palette.DatePill.tint)"), 1)
        XCTAssertEqual(Self.count(Self.datePillTint, in: ".tint(Palette.accent)"), 0)
        XCTAssertEqual(Self.count(Self.picker, in: #"PagePicker("Парцел", selection: $p, value: v, choices: c)"#), 0)
    }
}
