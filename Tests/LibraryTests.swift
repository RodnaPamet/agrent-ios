import XCTest
@testable import Agrent

/// «Вдъхновение» (#580): the library's shelves, a book and its notes,
/// against agri-saas #2980. Fixtures are an invented book only.
final class LibraryTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func testThePathsAreOutsideTheFarm() {
        XCTAssertEqual(LibraryAPI.listPath, "/api/library/books")
        XCTAssertEqual(LibraryAPI.bookPath("izkustvoto-na-voynata"), "/api/library/books/izkustvoto-na-voynata")
        XCTAssertFalse(LibraryAPI.listPath.hasPrefix("/api/t/"), "the same for every farm and every role")
    }

    func testTheShelfReadsAndGroups() async throws {
        let books = try await LibraryAPI.decodeList(fixture("library-books"))
        XCTAssertEqual(books.map(\.slug), ["sintetichna-kniga", "bez-rafiya"])
        let shelves = BookUseCase.shelves(books)
        XCTAssertEqual(shelves.map(\.label), ["Стратегия", "Други"])
        XCTAssertEqual(shelves[1].books.map(\.slug), ["bez-rafiya"], "no use case: «Други»")
        XCTAssertEqual(BookUseCase.label("unknown-code"), "Други")
        XCTAssertEqual(BookUseCase.label("STRATEGY"), "Стратегия", "the server's codes are capitals")
        XCTAssertEqual(BookUseCase.label("strategy"), "Стратегия")
    }

    func testABookReadsInChapterOrderWithItsNotes() async throws {
        let book = try await LibraryAPI.decodeBook(fixture("library-book"))
        XCTAssertEqual(book.summary.title, "Синтетична книга")
        XCTAssertEqual(book.chapters.map(\.number), [1, 2], "sorted, whatever order the server sent")
        XCTAssertEqual(book.chapters.first?.originalTitle, "第一")
        XCTAssertEqual(BookWords.about(book),
                       "Превод: Agrent.\n\nИзмислен текст за изпитване, без истински източник.\n\nСвободен за използване.")
    }

    func testABadChapterCostsOnlyItself() async throws {
        let book = try await LibraryAPI.decodeBook(Data(#"""
        {"slug":"x","title":"X","chapters":[{"number":1,"title":"A","paragraphs":["a"]},{"title":"no number"}]}
        """#.utf8))
        XCTAssertEqual(book.chapters.map(\.number), [1])
        XCTAssertEqual(BookWords.about(book), "", "nothing to say, nothing shown")
    }
}
