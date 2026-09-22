import XCTest
@testable import Agrent

/// The two payload strings in `liveNotes` are not invented. They were read out
/// of the app's own `ResponseCache` on 2026-09-22 after a live load of the
/// production tenant, and they are ALL of the notes that tenant holds: 2 of 2
/// entries with a `notes` value contain HTML. The format is not an edge case.
final class RichTextTests: XCTestCase {

    // MARK: - The measured payload

    func testLivePayloadRendersWithoutTags() {
        let liveNotes = [
            "<p>Sample input-application record.</p>",
            "<p>Sample observation — good establishment after rain.</p>",
        ]
        let expected = [
            "Sample input-application record.",
            "Sample observation — good establishment after rain.",
        ]
        for (html, want) in zip(liveNotes, expected) {
            XCTAssertEqual(RichText.plainText(html), want)
        }
    }

    // MARK: - Never eat the operator's words

    /// Conservatism 1. A note that is not HTML must survive untouched, and a
    /// bare `<` in agronomy prose is ordinary: doses, temperatures, pH.
    func testPlainTextWithComparisonIsReturnedVerbatim() {
        let note = "температура < 5°C, pH > 7 — не пръскай"
        XCTAssertEqual(RichText.plainText(note), note)
    }

    /// Conservatism 2, and the reason the tag list is explicit rather than
    /// `<[^>]*>`. The greedy pattern matches from the bare `<` to the `>` that
    /// closes `</p>` and deletes the number. Losing a measurement silently is
    /// strictly worse than showing a tag.
    func testComparisonInsideHTMLKeepsItsNumber() {
        let out = RichText.plainText("<p>температура < 5°C</p>")
        XCTAssertTrue(out.contains("5"), "the measurement was swallowed: \(out)")
        XCTAssertTrue(out.contains("температура"))
    }

    /// An unrecognised tag stays visible rather than taking its contents with
    /// it. Visible and reportable beats invisible and lost.
    func testUnknownTagKeepsItsContents() {
        XCTAssertTrue(RichText.plainText("<p>преди <custom>вътре</custom> след</p>").contains("вътре"))
    }

    // MARK: - Structure

    func testParagraphsBecomeBlankLineSeparated() {
        XCTAssertEqual(RichText.plainText("<p>Първи</p><p>Втори</p>"), "Първи\n\nВтори")
    }

    func testLineBreakBecomesNewline() {
        XCTAssertEqual(RichText.plainText("<p>Ред едно<br>Ред две</p>"), "Ред едно\nРед две")
    }

    func testListItemsAreBulletedOnSeparateLines() {
        let out = RichText.plainText("<ul><li>Азот</li><li>Фосфор</li></ul>")
        XCTAssertEqual(out, "• Азот\n\n• Фосфор")
    }

    func testInlineFormattingIsRemovedWithoutLosingText() {
        XCTAssertEqual(RichText.plainText("<p>Внесен <strong>азот</strong> днес</p>"),
                       "Внесен азот днес")
    }

    /// Empty markup is a real state: the web editor saves `<p></p>` for a note
    /// the author opened and left blank. It must reach the view as empty so the
    /// "Няма бележки" branch runs instead of a blank area that reads as a
    /// failure to load.
    func testEmptyMarkupBecomesEmptyString() {
        XCTAssertEqual(RichText.plainText("<p></p>"), "")
        XCTAssertEqual(RichText.plainText("<p><br></p>"), "")
    }

    // MARK: - Entities

    func testNamedAndNumericEntitiesDecode() {
        XCTAssertEqual(RichText.plainText("<p>N &amp; P</p>"), "N & P")
        XCTAssertEqual(RichText.plainText("<p>18 &deg;C</p>"), "18 °C")
        XCTAssertEqual(RichText.plainText("<p>&#1055;&#1086;&#1083;&#1077;</p>"), "Поле")
        XCTAssertEqual(RichText.plainText("<p>&#x41F;&#x43E;</p>"), "По")
    }

    /// `&nbsp;` deliberately becomes an ordinary space. A non-breaking space
    /// forbids a wrap at exactly the point Dynamic Type at `accessibility3`
    /// needs one, which is the overflow class this app has already shipped
    /// twice.
    func testNonBreakingSpaceBecomesBreakable() {
        let out = RichText.plainText("<p>50&nbsp;кг</p>")
        XCTAssertEqual(out, "50 кг")
        XCTAssertFalse(out.unicodeScalars.contains("\u{00A0}"))
    }

    /// The single-pass requirement, stated as a test. A chain of
    /// `replacingOccurrences` decodes `&amp;` first, leaving `&lt;`, and then
    /// decodes THAT to `<`: one authored ampersand, two decodes, wrong answer.
    func testEntitiesAreDecodedOnceNotCascaded() {
        XCTAssertEqual(RichText.plainText("<p>&amp;lt;</p>"), "&lt;")
    }

    /// Order matters the other way too: an author who typed a literal tag,
    /// escaped by the editor, must still SEE that tag. Decoding before
    /// stripping would turn it back into markup and delete it.
    func testEscapedTagSurvivesAsText() {
        XCTAssertEqual(RichText.plainText("<p>пише &lt;p&gt; в текста</p>"), "пише <p> в текста")
    }

    func testUnknownEntityIsLeftAlone() {
        XCTAssertEqual(RichText.plainText("<p>&notanentity;</p>"), "&notanentity;")
    }
}
