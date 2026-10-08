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
    /// rich text reads as text: a `<br>` a line break, `&lt;` a `<`.
    func testTheDetailCarriesItsCommentsAsText() async throws {
        let task = try await WorkItemAPI.decodeDetail(from: try fixture("task-detail-task"))
        XCTAssertEqual(task.comments.map(\.id), ["cmt_synthetic_1", "cmt_synthetic_2"])
        XCTAssertEqual(task.comments[0].createdBy?.displayName, "Петър Механизаторов")
        XCTAssertEqual(task.comments[0].text, "Пробите от SYNTH-1 и SYNTH-2 са взети.\nSYNTH-3 остава за утре.")
        XCTAssertEqual(task.comments[1].text, "Добре. Резултатите трябват <до петък>.")
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

    /// Whitespace is nothing to send; text goes as rich text, its line
    /// breaks kept and its markup characters escaped.
    func testADraftIsSentAsRichText() {
        XCTAssertEqual(TaskCommentRules.validate("  \n "), .empty)
        XCTAssertEqual(TaskCommentRules.validate(" Готово.\nОстава SYNTH-3 "),
                       .sendable("<p>Готово.<br>Остава SYNTH-3</p>"))
        XCTAssertEqual(TaskCommentRules.validate("a < b"), .sendable("<p>a &lt; b</p>"))
    }

    /// The limit is the route's, on what is SENT: escaping makes the rich
    /// text longer than what was typed, so 2500 typed `<` are 10000 sent
    /// units of `&lt;` plus the paragraph — over.
    func testTheLimitIsMeasuredOnWhatIsSent() {
        let typed = String(repeating: "<", count: 2500)
        XCTAssertEqual(typed.utf16.count, 2500)
        XCTAssertEqual(TaskCommentRules.validate(typed), .tooLong)
        let fits = String(repeating: "а", count: TaskCommentRules.maxLength - "<p></p>".utf16.count)
        XCTAssertTrue(TaskCommentRules.validate(fits).isSendable)
        XCTAssertEqual(TaskCommentRules.validate(fits + "а"), .tooLong)
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
