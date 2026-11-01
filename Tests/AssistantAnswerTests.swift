import XCTest
@testable import Agrent

/// The assistant's answer as blocks (owner, 2026-11-01: a Markdown table
/// reached the screen as rows of «|»).
final class AssistantAnswerTests: XCTestCase {

    /// The owner's own answer, as the model wrote it.
    private let owners = """
    В Дневника ти има **8 записа** общо. Ето разбивка по вид:

    | Вид | Брой |
    |---|---|
    | Дейност | 3 |
    | Внасяне на препарат/тор | 3 |
    | Присаждане/разсаждане | 1 |
    | Наблюдение | 1 |

    Всички записи са изпълнени. Искаш ли да разгледаме някой от тях по-подробно?
    """

    func testATableIsATableNotPipes() {
        let blocks = AssistantAnswer.blocks(owners)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("В Дневника ти има **8 записа** общо. Ето разбивка по вид:"))
        XCTAssertEqual(blocks[1], .table(header: ["Вид", "Брой"], rows: [
            ["Дейност", "3"], ["Внасяне на препарат/тор", "3"], ["Присаждане/разсаждане", "1"], ["Наблюдение", "1"],
        ]))
        guard case .paragraph = blocks[2] else { return XCTFail("the closing sentence is not a paragraph") }
    }

    /// VoiceOver hears words: no pipes, no rule, no Markdown marks.
    func testTheSpokenAnswerHasNoMarks() {
        let spoken = AssistantAnswer.spoken(owners)
        XCTAssertFalse(spoken.contains("|"))
        XCTAssertFalse(spoken.contains("---"))
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertTrue(spoken.contains("Дейност, 3"))
        XCTAssertTrue(spoken.contains("8 записа"))
    }

    func testListsAndHeadings() {
        let blocks = AssistantAnswer.blocks("""
        ## Какво да направите
        - Проверете влагата
        * Пръскайте вечер
        1. Първо
        2) Второ
        Обикновен ред.
        """)
        XCTAssertEqual(blocks, [
            .heading("Какво да направите"),
            .bullets(["Проверете влагата", "Пръскайте вечер"]),
            .numbered(["Първо", "Второ"]),
            .paragraph("Обикновен ред."),
        ])
        XCTAssertEqual(AssistantAnswer.blocks("2026. Годината беше добра."), [.paragraph("2026. Годината беше добра.")],
                       "a year is not a numbered list")
    }

    /// A row the model got wrong still lines up; a table without a rule has
    /// no header rather than eating its first row.
    func testAnUnevenTableStillReads() {
        XCTAssertEqual(AssistantAnswer.blocks("| А | Б | В |\n|---|:-:|---:|\n| 1 | 2 |\n| 3 | 4 | 5 | 6 |"),
                       [.table(header: ["А", "Б", "В"], rows: [["1", "2", ""], ["3", "4", "5"]])])
        XCTAssertEqual(AssistantAnswer.blocks("| Торове | 3 |\n| Семена | 1 |"),
                       [.table(header: ["", ""], rows: [["Торове", "3"], ["Семена", "1"]])])
    }
}
