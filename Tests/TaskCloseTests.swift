import XCTest
@testable import Agrent

/// The green tick's form (#226): who may close, what the note says, what
/// the parcels are told — and the weed list it asks from.
final class TaskCloseTests: XCTestCase {

    /// The plain task's fixture, its status and assignee varied.
    private func task(status: String = "IN_PROGRESS", assignee: String? = "usr_fixture_operator",
                      key: String? = nil) async throws -> WorkItem {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "task-detail-task", withExtension: "json"))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["status"] = status
        json["assigneeUserId"] = assignee ?? NSNull()
        json["key"] = key ?? NSNull()
        return try await WorkItemAPI.decodeDetail(from: try JSONSerialization.data(withJSONObject: json))
    }

    private func me(_ role: String?, id: String = "usr_me") -> CurrentUser {
        CurrentUser(id: id, name: nil, email: nil, role: role)
    }

    // MARK: - Who

    /// Write permission, or the task's assignee — `setTaskStatus`'s rule —
    /// and only while CLOSED is still a move the task can make.
    func testTheAssigneeOrAWriterMayCloseAnOpenTask() async throws {
        let open = try await task()
        XCTAssertTrue(TaskCloseRules.mayClose(open, me: me("OWNER")))
        XCTAssertTrue(TaskCloseRules.mayClose(open, me: me("MECHANISATOR", id: "usr_fixture_operator")),
                      "the assigned mechanisator closes their own task")
        XCTAssertFalse(TaskCloseRules.mayClose(open, me: me("MECHANISATOR")),
                       "a mechanisator who is not the assignee")
        XCTAssertFalse(TaskCloseRules.mayClose(open, me: me("READER")))
        XCTAssertFalse(TaskCloseRules.mayClose(open, me: nil), "nobody before /me answers")
        for status in ["CLOSED", "CANCELED"] {
            let finished = try await task(status: status)
            XCTAssertFalse(TaskCloseRules.mayClose(finished, me: me("OWNER")), status)
        }
    }

    // MARK: - What it asks

    func testQuestionOneIsRequiredAndTwoWhenAsked() {
        var answers = TaskCloseAnswers()
        XCTAssertFalse(TaskCloseRules.isComplete(answers, asksWeeds: false))
        answers.completed = false
        XCTAssertTrue(TaskCloseRules.isComplete(answers, asksWeeds: false), "«Не» is an answer")
        XCTAssertFalse(TaskCloseRules.isComplete(answers, asksWeeds: true), "the weeds question is not optional")
        answers.noWeeds = true
        XCTAssertTrue(TaskCloseRules.isComplete(answers, asksWeeds: true))
        answers.noWeeds = false
        answers.otherWeeds = " , "
        XCTAssertFalse(TaskCloseRules.isComplete(answers, asksWeeds: true), "commas alone name no weed")
        answers.otherWeeds = "татул"
        XCTAssertTrue(TaskCloseRules.isComplete(answers, asksWeeds: true))
    }

    // MARK: - What it sends

    /// The note, a line per answer: names in the catalogue's order whatever
    /// order they were tapped in, the written-in ones after, the comment
    /// trimmed — and no weeds line when the question was not asked.
    func testTheClosingNoteSaysEachAnswer() {
        var answers = TaskCloseAnswers(completed: true)
        answers.weeds = ["Galium aparine", "Sorghum halepense"]
        answers.otherWeeds = "татул; пирей"
        answers.comment = "  Остана SYNTH-3.  "
        XCTAssertEqual(TaskCloseRules.resolution(answers, asksWeeds: true), """
            Изпълнена успешно: да.
            Плевели: Балур (Sorghum halepense), Лепка (Galium aparine), татул, пирей.
            Коментар: Остана SYNTH-3.
            """)
        let none = TaskCloseAnswers(completed: false, noWeeds: true)
        XCTAssertEqual(TaskCloseRules.resolution(none, asksWeeds: true), "Изпълнена успешно: не.\nПлевели: няма.")
        XCTAssertEqual(TaskCloseRules.resolution(none, asksWeeds: false), "Изпълнена успешно: не.")
    }

    /// The parcels get binomials then free text, one list the server sorts;
    /// nothing at all for «Няма плевели».
    func testTheParcelsGetBinomialsThenFreeText() {
        var answers = TaskCloseAnswers(completed: true)
        answers.weeds = ["Cirsium arvense", "Avena fatua"]
        answers.otherWeeds = "татул,\nпирей"
        XCTAssertEqual(TaskCloseRules.weedsToRecord(answers), ["Avena fatua", "Cirsium arvense", "татул", "пирей"])
        answers.noWeeds = true
        XCTAssertEqual(TaskCloseRules.weedsToRecord(answers), [])
    }

    /// The note's limit is the route's, measured on the note.
    func testALongCommentIsCaughtBeforeSending() {
        var answers = TaskCloseAnswers(completed: true)
        answers.comment = String(repeating: "а", count: TaskCloseRules.resolutionMaxLength)
        XCTAssertTrue(TaskCloseRules.isTooLong(answers, asksWeeds: false))
        answers.comment = "Добре."
        XCTAssertFalse(TaskCloseRules.isTooLong(answers, asksWeeds: false))
    }

    func testTheObservationSaysWhichTaskSawTheWeeds() async throws {
        let keyed = try await task(key: "FT-103")
        let unkeyed = try await task()
        XCTAssertEqual(TaskCloseRules.observationNote(keyed), "Задача FT-103: Заявка за анализ на почвата")
        XCTAssertEqual(TaskCloseRules.observationNote(unkeyed), "Задача Заявка за анализ на почвата")
        XCTAssertEqual(TaskCloseText.weedsNotRecorded(parcels: 2, reason: "Нямате права."),
                       "Задачата е затворена и плевелите са в бележката към нея, но не са записани в 2 парцела: Нямате права.")
    }

    // MARK: - The list

    /// The form's groups come from the app's ONE catalogue (`WeedCatalogue`,
    /// pinned to the spec by `ParcelHistoryTests`): five grasses, the rest
    /// broadleaves, every grass a catalogue binomial — and a row's name is
    /// the table's, without the Latin.
    func testTheFormsGroupsAreTheCataloguesOwn() {
        XCTAssertEqual(WeedCatalogue.grasses.count, 5)
        XCTAssertTrue(WeedCatalogue.grasses.isSubset(of: Set(WeedCatalogue.binomials)))
        XCTAssertEqual(Array(WeedCatalogue.binomials.prefix(5)).filter(WeedCatalogue.grasses.contains).count, 5,
                       "the grasses come first, as the server orders them")
        XCTAssertEqual(WeedCatalogue.rowName(for: "Sorghum halepense"), "Балур")
        XCTAssertEqual(WeedCatalogue.rowName(for: "Lolium perenne"), "Lolium perenne", "unknown keys stay Latin")
    }
}
