import XCTest
@testable import Agrent

/// A parcel's comments (#465, agri-saas #2476): the route, the agreed rows,
/// and what the card says.
final class ParcelCommentsTests: XCTestCase {

    private func fixture() async throws -> ParcelComments {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "parcel-comments", withExtension: "json"))
        return try await ParcelCommentsAPI.decode(from: Data(contentsOf: url))
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!

    /// The parcel's id in the path, escaped, and no query.
    func testTheParcelIsAPathSegment() {
        let path = ParcelCommentsAPI.path("par 1")
        XCTAssertTrue(path.hasSuffix("/agro/parcels/par%201/comments"), path)
        XCTAssertTrue(path.hasPrefix(FarmPath.root), path)
        XCTAssertFalse(path.contains("?"), path)
    }

    /// Both kinds decode. A closing note names nobody and says what it is;
    /// a comment names its author.
    func testACommentNamesItsAuthorAndAClosingNoteNobody() async throws {
        let comments = try await fixture()
        XCTAssertEqual(comments.items.map(\.kind), [.comment, .resolution])
        XCTAssertFalse(comments.truncated)
        let comment = try XCTUnwrap(comments.items.first)
        XCTAssertEqual(comment.who, "Петър Механизаторов")
        XCTAssertEqual(comment.task, "FT-102 Пръскане срещу плевели")
        let note = try XCTUnwrap(comments.items.last)
        XCTAssertNil(note.createdBy)
        XCTAssertEqual(note.who, "При затваряне на задачата")
        XCTAssertEqual(note.id, "resolution:tsk_fixture_parcel_done")
    }

    /// An unknown kind and a null key cost nothing: the row still reads.
    func testAnUnknownKindAndANullKeyStillRead() async throws {
        let body = #"""
        {"rows":[{"id":"x","taskId":"t","taskKey":null,"taskTitle":"Оглед","kind":"SOMETHING_NEW","body":" Добре. ",
                  "createdAt":"2026-10-01T06:00:00.000Z","createdByUserId":null,"createdBy":null}],"truncated":true}
        """#
        let comments = try await ParcelCommentsAPI.decode(from: Data(body.utf8))
        let row = try XCTUnwrap(comments.items.first)
        XCTAssertEqual(row.kind, .unknown)
        XCTAssertEqual(row.task, "Оглед")
        XCTAssertEqual(row.text, "Добре.")
        XCTAssertNil(row.who)
        XCTAssertTrue(comments.truncated)
    }

    /// A note on the parcel itself (agri-saas, owner 2026-11-06): no task,
    /// so the three task fields are null. The list still reads, the note
    /// names its author and no task, and the card shows it.
    func testAParcelsOwnNoteReads() async throws {
        let body = #"""
        {"rows":[
          {"id":"n1","kind":"PARCEL","taskId":null,"taskKey":null,"taskTitle":null,"body":"Синтетична бележка",
           "createdAt":"2026-11-06T18:00:00.000Z","createdByUserId":"u1","createdBy":{"id":"u1","name":"Синтетичен Потребител","email":null}},
          {"id":"c1","kind":"COMMENT","taskId":"t","taskKey":"TSK-1","taskTitle":"Оглед","body":"Добре.",
           "createdAt":"2026-11-01T06:00:00.000Z","createdByUserId":null,"createdBy":null}],"truncated":false}
        """#
        let comments = try await ParcelCommentsAPI.decode(from: Data(body.utf8))
        XCTAssertEqual(comments.items.count, 2)
        let note = comments.items[0]
        XCTAssertEqual(note.kind, .parcel)
        XCTAssertNil(note.taskId)
        XCTAssertNil(note.task, "a note names no task")
        XCTAssertEqual(note.who, "Синтетичен Потребител")
        XCTAssertEqual(comments.items[1].task, "TSK-1 Оглед", "positive control: a task's comment still names it")
        let card = ParcelCommentsCard(comments, now: now)
        XCTAssertEqual(card.line.headline, "Синтетична бележка")
    }

    // MARK: - The card

    /// The newest comment: what it says, then who, the day and the task,
    /// under how many there are.
    func testTheCardShowsTheNewest() async throws {
        let card = ParcelCommentsCard(try await fixture(), now: now)
        XCTAssertEqual(card.count, "2 коментара")
        XCTAssertEqual(card.line.headline, "Спряхме заради вятъра, продължаваме утре сутрин.")
        XCTAssertEqual(card.line.details.first, "Петър Механизаторов")
        XCTAssertEqual(card.line.details.last, "FT-102 Пръскане срещу плевели")
        XCTAssertTrue(card.isTappable)
        XCTAssertEqual(card.headlineLimit, 3)
        XCTAssertTrue(card.spoken.hasPrefix("Коментари, 2 коментара, Спряхме"), card.spoken)
    }

    /// None: one calm line, and it still opens (owner, 2026-11-06).
    func testNoCommentsStillOpens() {
        let card = ParcelCommentsCard(ParcelComments(items: [], truncated: false), now: now)
        XCTAssertNil(card.count)
        XCTAssertEqual(card.line.details, ["Няма коментари"])
        XCTAssertTrue(card.isTappable)
    }

    /// A capped list is not counted.
    func testACappedListIsNotCounted() async throws {
        let all = try await fixture()
        let card = ParcelCommentsCard(ParcelComments(items: all.items, truncated: true), now: now)
        XCTAssertNil(card.count)
        XCTAssertTrue(card.isTappable, "positive control: the comments are still there")
    }
}
