import XCTest
@testable import Agrent

/// «Редактирай» on a task (#382): who is offered it, what the form opens on,
/// and that only what changed is sent. Synthetic task and people.
final class TaskEditTests: XCTestCase {

    /// The plain task's fixture: created by `usr_fixture_owner`, assigned to
    /// `usr_fixture_operator`, due 2026-10-08 at 07:00 UTC (not midnight).
    private func task(description: String? = nil, dueAt: String? = nil,
                      noDue: Bool = false) async throws -> WorkItem {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "task-detail-task", withExtension: "json"))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        if let description { json["description"] = description }
        if let dueAt { json["dueAt"] = dueAt }
        if noDue { json["dueAt"] = NSNull() }
        return try await WorkItemAPI.decodeDetail(from: try JSONSerialization.data(withJSONObject: json))
    }

    private func me(id: String, canWrite: Bool? = true, canAdmin: Bool? = false) -> CurrentUser {
        CurrentUser(id: id, name: nil, email: nil, role: nil,
                    permissions: canWrite.map { CurrentUser.Permissions(canWrite: $0, canAdmin: canAdmin) })
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    // MARK: - Who

    /// The creator and the farm's administrators (owner, 2026-10-21), and
    /// only someone who may write.
    func testTheCreatorAndAdministratorsAreOfferedIt() async throws {
        let item = try await task()
        XCTAssertTrue(TaskEdit.mayEdit(item, me: me(id: "usr_fixture_owner")), "the creator")
        XCTAssertTrue(TaskEdit.mayEdit(item, me: me(id: "usr_someone", canAdmin: true)), "an administrator")
        XCTAssertFalse(TaskEdit.mayEdit(item, me: me(id: "usr_someone")), "another writer")
        XCTAssertFalse(TaskEdit.mayEdit(item, me: me(id: "usr_fixture_operator", canWrite: false)),
                       "the assignee who may not write")
        XCTAssertFalse(TaskEdit.mayEdit(item, me: me(id: "usr_fixture_owner", canWrite: false)),
                       "a creator who may no longer write")
        XCTAssertFalse(TaskEdit.mayEdit(item, me: nil), "nobody before /me answers")
    }

    /// No tier told: offered, as every write is, and the server answers.
    func testItFailsOpenWhenTheTierIsUnknown() async throws {
        let item = try await task()
        XCTAssertTrue(TaskEdit.mayEdit(item, me: me(id: "usr_someone", canWrite: nil)))
        XCTAssertTrue(TaskEdit.mayEdit(item, me: me(id: "usr_someone", canAdmin: nil)),
                      "a farm remembered before canAdmin")
    }

    // MARK: - The form as opened

    func testTheFormOpensOnTheTaskAsItStands() async throws {
        let draft = TaskEdit.draft(from: try await task())
        XCTAssertEqual(draft.title, "Заявка за анализ на почвата")
        XCTAssertEqual(draft.details, "Синтетична задача: проби от почвата на трите парцела.")
        XCTAssertTrue(draft.hasDue)
        XCTAssertEqual(BgDate.isoDay(draft.due), "2026-10-08")
        XCTAssertEqual(draft.assigneeID, "usr_fixture_operator")
        XCTAssertNil(draft.problem)
    }

    /// An envelope the server didn't decrypt is not text to edit.
    func testAnUndecryptedDescriptionOpensEmpty() async throws {
        let draft = TaskEdit.draft(from: try await task(description: "v1:AAAAbbbbCCCCddddEEEE"))
        XCTAssertEqual(draft.details, "")
        XCTAssertTrue(TaskEdit.changes(from: draft, to: draft).isEmpty, "and is not sent unless typed over")
    }

    func testNoDueDayOpensWithTheToggleOff() async throws {
        let draft = TaskEdit.draft(from: try await task(noDue: true))
        XCTAssertFalse(draft.hasDue)
    }

    // MARK: - What is sent

    func testNothingChangedSendsNothing() async throws {
        let original = TaskEdit.draft(from: try await task())
        var edited = original
        edited.title += "  "
        XCTAssertTrue(TaskEdit.changes(from: original, to: edited).isEmpty, "trailing spaces are no change")
    }

    /// The day is compared, not the instant: an untouched due day that sits
    /// at 07:00 is not rewritten to midnight by an edit of the title.
    func testAnUntouchedDueDayIsNotRewritten() async throws {
        let original = TaskEdit.draft(from: try await task())
        var edited = original
        edited.title = "Анализ на почвата"
        let sent = try json(TaskEdit.changes(from: original, to: edited).patch)
        XCTAssertEqual(sent as NSDictionary, ["title": "Анализ на почвата"] as NSDictionary)
    }

    /// Cleared fields go out as an explicit null, which the route reads as
    /// "remove". An absent key would leave them.
    func testClearingSendsNull() async throws {
        let original = TaskEdit.draft(from: try await task())
        var edited = original
        edited.details = "   "
        edited.hasDue = false
        let sent = try json(TaskEdit.changes(from: original, to: edited).patch)
        XCTAssertEqual(Set(sent.keys), ["description", "dueAt"])
        XCTAssertTrue(sent["description"] is NSNull)
        XCTAssertTrue(sent["dueAt"] is NSNull)
    }

    func testANewDueDayIsSentAsTheWebSendsIt() async throws {
        let original = TaskEdit.draft(from: try await task(noDue: true))
        var edited = original
        edited.hasDue = true
        edited.due = try XCTUnwrap(BgDate.parseISODay("2026-11-02"))
        let sent = try json(TaskEdit.changes(from: original, to: edited).patch)
        XCTAssertEqual(sent["dueAt"] as? String, "2026-11-02T00:00:00.000Z")
    }

    /// The assignee goes to its own route, and only when it changed.
    /// The server's refusal of someone else's task (agri-saas #2182), in Bulgarian.
    func testTheServersRefusalIsBulgarian() {
        let text = UserMessage.text(for: APIClient.APIError.http(
            status: 403, code: "TASK_EDIT_NOT_PERMITTED", message: "Only the creator"))
        XCTAssertFalse(text.contains("Only"))
        XCTAssertTrue(text.contains("администратор"))
        XCTAssertTrue(text.hasSuffix("."))
    }

    func testTheAssigneeIsItsOwnChange() async throws {
        let original = TaskEdit.draft(from: try await task())
        var edited = original
        edited.assigneeID = "usr_fixture_owner"
        var changes = TaskEdit.changes(from: original, to: edited)
        XCTAssertTrue(changes.patch.isEmpty, "the fields are untouched")
        XCTAssertEqual(changes.assignee, .some("usr_fixture_owner"))

        edited.assigneeID = nil
        changes = TaskEdit.changes(from: original, to: edited)
        XCTAssertEqual(changes.assignee, .some(nil), "«Без изпълнител» unassigns")
        XCTAssertFalse(changes.isEmpty)
    }

    /// `assigneeUserId` is required by the route, so «nobody» is a null,
    /// never an absent key.
    func testUnassigningSendsNull() throws {
        let sent = try json(TaskEditAPI.Assignment(assigneeUserId: nil))
        XCTAssertEqual(Set(sent.keys), ["assigneeUserId"])
        XCTAssertTrue(sent["assigneeUserId"] is NSNull)
    }

    // MARK: - The picker

    /// A current assignee the list left out still has a row, so the picker
    /// doesn't read «Без изпълнител» over a task that has one.
    func testTheCurrentAssigneeKeepsARow() async throws {
        let item = try await task()
        let base = [AssignableUsersStore.Choice(id: "usr_me", label: "Аз (Вие)")]
        let kept = TaskEdit.choices(base, keeping: item.assignee)
        XCTAssertEqual(kept.map(\.id), ["usr_me", "usr_fixture_operator"])
        XCTAssertEqual(kept.last?.label, "Петър Механизаторов")

        let listed = base + [AssignableUsersStore.Choice(id: "usr_fixture_operator", label: "Петър")]
        XCTAssertEqual(TaskEdit.choices(listed, keeping: item.assignee), listed, "no second row")
        XCTAssertEqual(TaskEdit.choices(base, keeping: nil), base)
    }
}
