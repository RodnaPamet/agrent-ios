import XCTest
@testable import Agrent

/// Soft hyphens for the farm wizard's long words (#210): shown at the
/// accessibility sizes, never spoken.
final class SoftHyphensTests: XCTestCase {

    private let shy = "\u{AD}"

    func testTheLongWordsGetTheirSyllableBreaks() {
        XCTAssertEqual(SoftHyphens.display("Какво е стопанството Ви?"),
                       "Какво е сто\(shy)пан\(shy)ство\(shy)то Ви?")
        XCTAssertEqual(SoftHyphens.display("Стопанство с ЕИК"), "Сто\(shy)пан\(shy)ство с ЕИК")
        XCTAssertEqual(SoftHyphens.display("Стопанството Ви е онлайн"),
                       "Сто\(shy)пан\(shy)ство\(shy)то Ви е онлайн")
    }

    /// The composers' prompts (#225), broken at AX5 beside their send arrows.
    func testTheComposerPromptsBreakAtASyllable() {
        XCTAssertEqual(SoftHyphens.display("Напишете съобщение…"),
                       "На\(shy)пи\(shy)ше\(shy)те съоб\(shy)ще\(shy)ние…")
        XCTAssertEqual(SoftHyphens.display("Напишете коментар…"), "На\(shy)пи\(shy)ше\(shy)те коментар…")
    }

    /// Invisible: take the soft hyphens out and every wizard string is itself
    /// again — what the accessibility label carries.
    func testDisplayChangesNothingButTheBreaks() {
        let strings = [FarmWizardText.typeTitle, FarmWizardText.typeCompany, FarmWizardText.eikTitle,
                       FarmWizardText.farmNameTitle, FarmWizardText.doneTitle, FarmWizardText.doneOpen,
                       FarmWizardText.typeIndividual, FarmWizardText.addTitle]
        for text in strings {
            XCTAssertEqual(SoftHyphens.display(text).replacingOccurrences(of: shy, with: ""), text)
        }
        XCTAssertEqual(SoftHyphens.display("Земеделски стопанин"), "Земеделски стопанин",
                       "a word not in the table is left alone")
    }

    /// The wizard shows the hyphenated words and SPEAKS the plain ones:
    /// read from the source, since a label has no runtime reader here.
    @MainActor
    func testTheWizardSpeaksThePlainWords() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/Account/FarmWizardView.swift")
        let code = SignOutHygieneTests.code(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(code.contains("struct KindChoice"), "positive control: the wizard moved")
        XCTAssertEqual(code.components(separatedBy: "Text(SoftHyphens.display(title))").count - 1, 2,
                       "the heading and the choice title both hyphenate")
        XCTAssertEqual(code.components(separatedBy: ".accessibilityLabel(title)").count - 1, 2,
                       "and both speak the plain words")
    }
}
