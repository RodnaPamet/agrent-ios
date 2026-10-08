import XCTest
@testable import Agrent

/// A task's comments (agrent-ios#225): read off the task's detail, shown as
/// text, and checked before they are sent.
final class TaskCommentsTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    // MARK: - Reading

    /// The detail carries them oldest first, with their authors — and the
    /// stored plain text is shown as stored: a newline a line break, a `<`
    /// a `<`, as the web shows it.
    func testTheDetailCarriesItsCommentsAsText() async throws {
        let task = try await WorkItemAPI.decodeDetail(from: try fixture("task-detail-task"))
        XCTAssertEqual(task.comments.map(\.id), ["cmt_synthetic_1", "cmt_synthetic_2"])
        XCTAssertEqual(task.comments[0].createdBy?.displayName, "Петър Механизаторов")
        XCTAssertEqual(task.comments[0].text, "Пробите от SYNTH-1 и SYNTH-2 са взети.\nSYNTH-3 остава за утре.")
        XCTAssertEqual(task.comments[1].text, "Добре. Резултатите трябват до петък — и при < 5 проби.")
        XCTAssertNotNil(task.comments[1].createdAt)
    }

    /// A comment this build cannot read costs that comment, never the task;
    /// and a task without the key has none.
    func testAnUnreadableCommentCostsOnlyItself() async throws {
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try fixture("task-detail-task")) as? [String: Any])
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        comments.insert(["id": 42], at: 0)
        json["comments"] = comments
        let task = try await WorkItemAPI.decodeDetail(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(task.comments.count, 2)

        json.removeValue(forKey: "comments")
        let bare = try await WorkItemAPI.decodeDetail(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(bare.comments, [])
    }

    // MARK: - Writing

    /// Whitespace is nothing to send; text goes as typed, trimmed — PLAIN
    /// text, which is what the route is. Rich text would lose its line
    /// breaks there: `sanitizePlainText` strips every tag, `<br>` included.
    func testADraftIsSentAsPlainText() {
        XCTAssertEqual(TaskCommentRules.validate("  \n "), .empty)
        XCTAssertEqual(TaskCommentRules.validate(" Готово.\nОстава SYNTH-3 "),
                       .sendable("Готово.\nОстава SYNTH-3"))
        XCTAssertEqual(TaskCommentRules.validate("a < b"), .sendable("a < b"), "nothing escaped")
    }

    /// The route's limit, in UTF-16 units of what is sent: 10000 Cyrillic
    /// letters fit, one more does not, and an emoji counts as two.
    func testTheLimitIsMeasuredOnWhatIsSent() {
        let fits = String(repeating: "а", count: TaskCommentRules.maxLength)
        XCTAssertTrue(TaskCommentRules.validate(fits).isSendable)
        XCTAssertEqual(TaskCommentRules.validate(fits + "а"), .tooLong)
        let emoji = String(repeating: "🌾", count: TaskCommentRules.maxLength / 2 + 1)
        XCTAssertEqual(TaskCommentRules.validate(emoji), .tooLong)
    }

    // MARK: - Who

    /// Anyone but a READER — the server's `assertCanCommentOnTasks` — and
    /// nobody before the app knows who is signed in.
    func testEveryoneButAReaderMayComment() {
        XCTAssertFalse(TaskCommentRules.mayComment(nil))
        for role in ["READER", "reader"] {
            XCTAssertFalse(TaskCommentRules.mayComment(CurrentUser(id: "u", name: nil, email: nil, role: role)), role)
        }
        for role in ["OWNER", "EDITOR", "MECHANISATOR", "AUDITOR", nil] as [String?] {
            XCTAssertTrue(TaskCommentRules.mayComment(CurrentUser(id: "u", name: nil, email: nil, role: role)),
                          String(describing: role))
        }
    }
}
