import XCTest
@testable import Agrent

/// «Какво помни асистентът» (#507, agri-saas #2686): what the assistant has
/// learned about the person, forgotten one point at a time behind five
/// seconds of «Отмени», all at once, or corrected. Nothing here reaches the
/// server: every call is a closure that records what it was asked. The
/// points are synthetic.
@MainActor
final class AssistantMemoryTests: XCTestCase {

    private typealias Point = AssistantMemoryAPI.Point

    private let wheat = Point(id: "m1", text: "Отглежда пшеница и слънчоглед.", rememberedAt: nil)
    private let short = Point(id: "m2", text: "Предпочита кратки отговори.", rememberedAt: nil)

    @MainActor
    private final class Calls {
        var log: [String] = []
        var refusal: Error?
    }

    private func store(_ calls: Calls, points: [Point]? = nil) -> AssistantMemoryStore {
        let points = points ?? [wheat, short]
        let api = AssistantMemoryStore.API(
            list: { points },
            forget: { id in
                calls.log.append("forget \(id)")
                if let refusal = calls.refusal { throw refusal }
            },
            forgetAll: {
                calls.log.append("forget all")
                if let refusal = calls.refusal { throw refusal }
            },
            edit: { id, text in
                calls.log.append("edit \(id) \(text)")
                if let refusal = calls.refusal { throw refusal }
                return Point(id: id, text: text, rememberedAt: nil)
            }
        )
        return AssistantMemoryStore(window: .seconds(600), api: api)
    }

    private func refusal(_ status: Int, _ code: String) -> Error {
        APIClient.APIError.http(status: status, code: code, message: nil)
    }

    // MARK: - The wire

    /// The envelope is `facts`; a point that does not read costs that point,
    /// never the list; a point without a readable day still shows.
    func testTheListDecodesLossily() async throws {
        let json = Data("""
        {"facts":[
          {"id":"m1","text":"Отглежда пшеница.","rememberedAt":"2026-10-30T08:15:00.000Z"},
          {"id":"m2","text":"Предпочита кратки отговори."},
          {"id":"m3"},
          {"id":"m4","text":"Има собствена техника.","rememberedAt":"not a date"}
        ]}
        """.utf8)
        let points = try await AssistantMemoryAPI.decodeList(from: json)
        XCTAssertEqual(points.map(\.id), ["m1", "m2", "m4"])
        XCTAssertNotNil(points[0].rememberedAt)
        XCTAssertNil(points[1].rememberedAt)
        XCTAssertNil(points[2].rememberedAt, "an unreadable day is no day, not a lost point")
    }

    /// Per person, under `/api/account`, never a farm's path; an id is one
    /// escaped segment.
    func testThePathsArePerPerson() {
        XCTAssertEqual(AssistantMemoryAPI.path, "/api/account/assistant-memory")
        XCTAssertEqual(AssistantMemoryAPI.pointPath("a b/c"), "/api/account/assistant-memory/a%20b%2Fc")
        XCTAssertFalse(AssistantMemoryAPI.path.contains("/api/t/"))
    }

    /// The server's refusals, in its Bulgarian.
    func testTheRefusalsAreBulgarian() {
        XCTAssertEqual(UserMessage.text(for: refusal(400, "MEMORY_POINT_EMPTY")), "Записът не може да бъде празен.")
        XCTAssertEqual(UserMessage.text(for: refusal(400, "MEMORY_POINT_INVALID")), "Този запис не е валиден.")
        XCTAssertEqual(UserMessage.text(for: refusal(404, "MEMORY_POINT_NOT_FOUND")), "Този запис не беше намерен.")
        XCTAssertEqual(AssistantMemoryStore.emptyRefusal, "Записът не може да бъде празен.")
    }

    // MARK: - One point, five seconds

    func testUndoSendsNothing() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        XCTAssertEqual(memory.points, [short], "gone from the list at once")
        XCTAssertEqual(memory.undoable, wheat)
        memory.undo()
        XCTAssertEqual(memory.points, [wheat, short])
        XCTAssertNil(memory.undoable)
        await memory.commit(wheat)
        XCTAssertEqual(calls.log, [], "an undone point is never sent, even if its window fires late")
    }

    func testTheWindowForgetsItOnce() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        await memory.commit(wheat)
        await memory.commit(wheat)
        XCTAssertEqual(calls.log, ["forget m1"])
        XCTAssertEqual(memory.points, [short])
        XCTAssertEqual(memory.state.value, [short], "out of the list itself, not only hidden")
        XCTAssertEqual(memory.hidden, [])
        XCTAssertNil(memory.undoable)
    }

    /// The bar names one point, so a second swipe sends the first then.
    func testASecondSwipeSendsTheFirst() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        memory.forget(short)
        XCTAssertEqual(memory.undoable, short)
        await settle { calls.log == ["forget m1"] }
        XCTAssertEqual(calls.log, ["forget m1"])
        XCTAssertEqual(memory.points, [])
        memory.undo()
        XCTAssertEqual(memory.points, [short], "«Отмени» brings back the one it names")
    }

    /// Leaving the screen inside the window: the store goes with it, so the
    /// point is sent then, not dropped after «Забравено» was read.
    func testLeavingSendsWhatWasSwiped() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        memory.flush()
        await settle { calls.log == ["forget m1"] }
        XCTAssertEqual(calls.log, ["forget m1"])
        await memory.commit(wheat)
        XCTAssertEqual(calls.log, ["forget m1"], "the window firing after does not send it again")
        memory.flush()
        XCTAssertEqual(calls.log, ["forget m1"], "nothing pending, nothing sent")
    }

    /// A refused forget puts the point back and says why.
    func testARefusalBringsItBack() async {
        let calls = Calls()
        calls.refusal = URLError(.notConnectedToInternet)
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        await memory.commit(wheat)
        XCTAssertEqual(memory.points, [wheat, short])
        XCTAssertNotNil(memory.failure)
    }

    // MARK: - All of it

    func testForgetAllEmptiesTheListAndCancelsTheWindow() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        await memory.forgetAll()
        XCTAssertEqual(calls.log, ["forget all"], "the swiped point goes with the rest, not on its own")
        XCTAssertEqual(memory.points, [])
        XCTAssertNil(memory.undoable)
        await memory.commit(wheat)
        XCTAssertEqual(calls.log, ["forget all"])
    }

    /// Nothing was forgotten, so nothing is missing, the swiped one included.
    func testARefusedForgetAllKeepsEverything() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        memory.forget(wheat)
        calls.refusal = URLError(.timedOut)
        await memory.forgetAll()
        XCTAssertEqual(memory.points, [wheat, short])
        XCTAssertNotNil(memory.failure)
    }

    // MARK: - A correction

    func testAnEmptyCorrectionIsRefusedBeforeSending() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        let said = await memory.edit(wheat, to: "  \n ")
        XCTAssertEqual(said, "Записът не може да бъде празен.")
        XCTAssertEqual(calls.log, [])
    }

    func testACorrectionIsTrimmedCappedAndShown() async {
        let calls = Calls()
        let memory = store(calls)
        await memory.load()
        let long = String(repeating: "я", count: AssistantMemoryAPI.maxLength + 20)
        let said = await memory.edit(wheat, to: "  \(long)\n")
        XCTAssertNil(said)
        let sent = String(repeating: "я", count: AssistantMemoryAPI.maxLength)
        XCTAssertEqual(calls.log, ["edit m1 \(sent)"])
        XCTAssertEqual(memory.points.first?.text, sent, "the list shows the server's answer")
        XCTAssertEqual(memory.points.count, 2)
    }

    /// Forgotten meanwhile, from the web: nothing left to correct.
    func testACorrectionOfAGonePointDropsIt() async {
        let calls = Calls()
        calls.refusal = refusal(404, "MEMORY_POINT_NOT_FOUND")
        let memory = store(calls)
        await memory.load()
        let said = await memory.edit(wheat, to: "Отглежда царевица.")
        XCTAssertEqual(said, "Този запис не беше намерен.")
        XCTAssertEqual(memory.points, [short])
    }

    // MARK: - The screen

    /// The bar quotes what went, so «Отмени» is about a sentence the person
    /// can still read.
    func testTheBarNamesThePoint() {
        XCTAssertEqual(AssistantMemoryText.forgotten(wheat), "Забравено: «Отглежда пшеница и слънчоглед.»")
    }

    /// Профил offers it only where the assistant AND its memory are on: the
    /// memory routes answer 404 while `assistant.memory` is off (a source
    /// read: the row is a `NavigationLink` inside a `List`, with no runtime
    /// hook).
    func testProfileOffersItBehindTheAssistantFlag() throws {
        let profile = try source("Agrent/Account/ProfileView.swift")
        let gate = try XCTUnwrap(profile.range(of: "if flags.isOn(AssistantAPI.flag), flags.isOn(AssistantMemoryAPI.flag) {"))
        let row = try XCTUnwrap(profile.range(of: "AssistantMemoryView()"))
        XCTAssertLessThan(gate.lowerBound, row.lowerBound)
        XCTAssertLessThan(profile.distance(from: gate.upperBound, to: row.lowerBound), 200,
                          "the row sits directly inside the flag check")
        // Positive control: the reader finds a row that is known to be there.
        XCTAssertTrue(profile.contains("DeleteAccountView()"))
    }

    // MARK: - Past conversations (#521)

    private let today = AssistantMemoryAPI.Conversation(id: "c1", opening: "Колко задачи имам?", lastTurnAt: nil, turns: 6)
    private let blank = AssistantMemoryAPI.Conversation(id: "c2", opening: nil, lastTurnAt: nil, turns: 0)

    private func conversations(_ calls: Calls) -> PastConversationsStore {
        let rows = [today, blank]
        return PastConversationsStore(window: .seconds(600), api: PastConversationsStore.API(
            list: { rows },
            forget: { id in
                calls.log.append("forget \(id)")
                if let refusal = calls.refusal { throw refusal }
            },
            forgetAll: {
                calls.log.append("forget all")
                if let refusal = calls.refusal { throw refusal }
            }))
    }

    /// The person's own first question labels a row; a blank one is no
    /// question; a row that does not read costs that row.
    func testConversationsDecodeLossily() async throws {
        let json = Data("""
        {"conversations":[
          {"id":"c1","startedAt":"2026-11-02T06:10:00.000Z","lastTurnAt":"2026-11-02T06:14:00.000Z","turns":6,"opening":"Колко задачи имам?"},
          {"id":"c2","startedAt":"2026-10-28T09:00:00.000Z","lastTurnAt":"2026-10-28T09:00:00.000Z","turns":0,"opening":null},
          {"id":"c3","startedAt":"2026-10-27T09:00:00.000Z","lastTurnAt":"2026-10-27T09:00:00.000Z","turns":2,"opening":"   "},
          {"opening":"без id"}
        ]}
        """.utf8)
        let rows = try await AssistantMemoryAPI.decodeConversations(from: json)
        XCTAssertEqual(rows.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(rows[0].opening, "Колко задачи имам?")
        XCTAssertEqual(rows[0].turns, 6)
        XCTAssertNotNil(rows[0].lastTurnAt)
        XCTAssertNil(rows[1].opening)
        XCTAssertNil(rows[2].opening, "spaces are no question")
    }

    func testTheConversationPathsArePerPerson() {
        XCTAssertEqual(AssistantMemoryAPI.conversationsPath, "/api/account/assistant-conversations")
        XCTAssertEqual(AssistantMemoryAPI.conversationPath("a b"), "/api/account/assistant-conversations/a%20b")
        XCTAssertEqual(AssistantMemoryAPI.flag, "assistant.memory")
    }

    /// The same five seconds as a point: hidden at once, undone for
    /// nothing, sent once.
    func testAConversationIsForgottenOnceAfterItsWindow() async {
        let calls = Calls()
        let list = conversations(calls)
        await list.load()
        list.forget(today)
        XCTAssertEqual(list.items, [blank])
        list.undo()
        XCTAssertEqual(list.items, [today, blank])
        XCTAssertEqual(calls.log, [])
        list.forget(today)
        await list.commit(today)
        await list.commit(today)
        XCTAssertEqual(calls.log, ["forget c1"])
        XCTAssertEqual(list.items, [blank])
    }

    func testForgettingAllConversationsLeavesThePoints() async {
        let calls = Calls()
        let list = conversations(calls)
        let memory = store(calls)
        await list.load()
        await memory.load()
        await list.forgetAll()
        XCTAssertEqual(calls.log, ["forget all"])
        XCTAssertEqual(list.items, [])
        XCTAssertEqual(memory.points, [wheat, short], "the points are their own")
        XCTAssertTrue(AssistantMemoryText.forgetAllConversationsNote.contains("Запомненото остава"))
        XCTAssertTrue(AssistantMemoryText.forgetAllNote.contains("Минали разговори остават"))
    }

    /// The bar quotes the question; a conversation without one still says
    /// what went.
    func testTheConversationBarNamesIt() {
        XCTAssertEqual(AssistantMemoryText.forgotten(today), "Разговорът е изтрит: «Колко задачи имам?»")
        XCTAssertEqual(AssistantMemoryText.forgotten(blank), "Разговорът е изтрит.")
    }

    // MARK: - Helpers

    /// Lets the unstructured send that `flush` and a second swipe start run.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<50 where !done() { await Task.yield() }
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
