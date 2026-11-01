import XCTest
@testable import Agrent

/// The assistant, phase 1 (#483, agri-saas #2578): the stream's lines, its
/// seven events, a turn from question to how it ended, every sentence in
/// Bulgarian, and the button's room above a screen's bars. Nothing here
/// reaches a server: a turn's events are handed in.
@MainActor
final class AssistantTests: XCTestCase {

    private func event(_ json: String) throws -> AssistantEvent {
        try JSONDecoder().decode(AssistantEvent.self, from: Data(json.utf8))
    }

    // MARK: - The stream's lines

    /// Only `data:` carries an event. The heartbeat and the stream's opening
    /// are comments; `event:` and `id:` are not used and are skipped.
    func testOnlyDataLinesAreEvents() {
        XCTAssertEqual(APIClient.eventPayload(#"data: {"type":"thinking"}"#), Data(#"{"type":"thinking"}"#.utf8))
        XCTAssertEqual(APIClient.eventPayload(#"data:{"type":"done"}"#), Data(#"{"type":"done"}"#.utf8))
        XCTAssertNil(APIClient.eventPayload(": hb"), "the heartbeat")
        XCTAssertNil(APIClient.eventPayload(":"), "the opening comment")
        XCTAssertNil(APIClient.eventPayload("event: answer"))
        XCTAssertNil(APIClient.eventPayload("id: 1"))
        XCTAssertNil(APIClient.eventPayload("data:"), "an empty payload")
        XCTAssertNil(APIClient.eventPayload(""))
    }

    // MARK: - The seven events

    func testTheSevenEventsDecode() throws {
        XCTAssertEqual(try event(#"{"type":"thinking"}"#), .thinking)
        XCTAssertEqual(try event(#"{"type":"tool_call","name":"list_tasks"}"#), .toolCall(name: "list_tasks"))
        XCTAssertEqual(try event(#"{"type":"tool_result","name":"list_tasks","ok":true,"truncated":false}"#),
                       .toolResult(name: "list_tasks", ok: true, truncated: false))
        XCTAssertEqual(try event(#"{"type":"answer","text":"Имате 3 задачи."}"#),
                       .answer(text: "Имате 3 задачи.", links: [], proposal: nil))
        XCTAssertEqual(try event(#"{"type":"refusal","code":"ASSISTANT_INPUT_REJECTED","message":"Не можах."}"#),
                       .refusal(reason: "ASSISTANT_INPUT_REJECTED", message: "Не можах."))
        XCTAssertEqual(try event(#"{"type":"halt","code":"ASSISTANT_SPEND_CEILING","message":"Непълен."}"#),
                       .halt(outcome: "ASSISTANT_SPEND_CEILING", message: "Непълен.", counts: [:]))
        XCTAssertEqual(try event(#"{"type":"refusal","reason":"ASSISTANT_INPUT_REJECTED"}"#),
                       .refusal(reason: "ASSISTANT_INPUT_REJECTED", message: nil), "the draft's name still reads")
        XCTAssertEqual(try event(#"{"type":"refusal","reason":"ASSISTANT_OUT_OF_SCOPE","message":"Извън."}"#),
                       .refusal(reason: "ASSISTANT_OUT_OF_SCOPE", message: "Извън."))
        XCTAssertEqual(try event(#"{"type":"halt","outcome":"ASSISTANT_TOOL_BUDGET","toolCalls":8,"limit":8}"#),
                       .halt(outcome: "ASSISTANT_TOOL_BUDGET", message: nil, counts: ["toolCalls": 8, "limit": 8]))
        XCTAssertEqual(try event(#"{"type":"done","truncatedAny":false}"#), .done(truncatedAny: false))
        XCTAssertEqual(try event(#"{"type":"done","truncatedAny":false,"partialAny":true}"#),
                       .done(truncatedAny: false, partialAny: true))
    }

    /// A type this build does not know is ignored, not a failure: the server
    /// may add one, and an older phone keeps working.
    func testAnUnknownTypeIsIgnored() throws {
        XCTAssertEqual(try event(#"{"type":"citation","href":"/journal"}"#), .unknown(type: "citation"))
        XCTAssertFalse(try event(#"{"type":"citation"}"#).ends)
        XCTAssertTrue(try event(#"{"type":"done"}"#).ends)
        XCTAssertTrue(try event(#"{"type":"refusal","reason":"X"}"#).ends)
        XCTAssertTrue(try event(#"{"type":"halt","outcome":"ASSISTANT_SPEND_CEILING"}"#).ends)
    }

    /// Phase 2's proposal decodes on a phase-1 phone rather than failing the
    /// answer it rides on.
    func testAProposalDoesNotBreakTheAnswer() throws {
        let answer = try event(#"{"type":"answer","text":"Готово.","proposal":{"kind":"cost","draft":{"amount":12}}}"#)
        XCTAssertEqual(answer, .answer(text: "Готово.", links: [], proposal: AssistantProposal(kind: "cost", draft: nil)))
    }

    /// Links are a field of their own, never Markdown in the text; a link
    /// is offered only where it leads to a bar tab on this phone.
    func testLinksAreAFieldAndOnlyFollowableOnesAreOffered() throws {
        let answer = try event(#"{"type":"answer","text":"Имате 3 задачи.","links":[{"route":"/farm-tasks","label":"Задачи"},{"route":"/trends","label":"Тенденции"},{"route":"/reports/x","label":"Отчет"}]}"#)
        guard case .answer(_, let links, _) = answer else { return XCTFail("not an answer") }
        XCTAssertEqual(links.map(\.route), ["/farm-tasks", "/trends", "/reports/x"])
        XCTAssertEqual(links[0].surface, .tasks)
        XCTAssertNil(links[2].surface)
        XCTAssertEqual(AssistantSheet.followable(links, bar: [.journal, .calculator, .exchange, .locations, .tasks],
                                                 farm: "synthetic-farm")
            .map(\.route), ["/farm-tasks"], "Тенденции is in the menu, not the bar; /reports/x is no screen")
        // A record, with its real id: opened as a notification's link is.
        // With or without the farm in front: the farm is the one open.
        XCTAssertEqual(AssistantLink(route: "/t/synthetic-farm/farm-tasks", label: "Задачи").surface, .tasks)
        XCTAssertEqual(AssistantLink(route: "/t/x/locations/loc_1", label: "Нива").page, "/locations/loc_1")
        let parcel = AssistantLink(route: "/locations/loc_synthetic", label: "Нива 4")
        XCTAssertEqual(parcel.screen(inFarm: "synthetic-farm"), .locationID("loc_synthetic"))
        XCTAssertEqual(AssistantLink(route: "/farm-tasks/t1", label: "Задача").screen(inFarm: "synthetic-farm"), .taskID("t1"))
        XCTAssertNil(parcel.screen(inFarm: nil), "no farm open, nothing to open")
        XCTAssertEqual(AssistantSheet.followable([parcel], bar: [], farm: "synthetic-farm"), [parcel])
        let broken = try event(#"{"type":"answer","text":"Да.","links":[{"route":5}]}"#)
        XCTAssertEqual(broken, .answer(text: "Да.", links: [], proposal: nil), "a broken links field costs the links only")
    }

    // MARK: - What the phone sends

    /// Identifiers only: the page route, no slug, nothing typed.
    func testTheRequestCarriesTheQuestionAndTheRouteOnly() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AssistantRequest(question: "Колко задачи имам?", pageContext: .surface(.calculator)))) as? [String: Any]
        XCTAssertEqual(Set(body?.keys ?? [:].keys), ["question", "pageContext"])
        let context = body?["pageContext"] as? [String: Any]
        XCTAssertEqual(context?.keys.sorted(), ["route"], "no field the server's .strict() would refuse")
        XCTAssertEqual(context?["route"] as? String, "/t/[tenantSlug]/grain/calculator",
                       "the page TEMPLATE, brackets intact: no farm and no id in it")
    }

    /// Every bar surface is a template in agri-saas #2591's generated set
    /// (`src/lib/assistant/generated/page-routes.ts` at 57ff1fe), pinned here
    /// so a renamed surface is a failing test rather than a 400.
    func testEverySurfaceIsAServerPageTemplate() {
        let served: Set<String> = [
            "/t/[tenantSlug]/journal", "/t/[tenantSlug]/grain/calculator", "/t/[tenantSlug]/exchange",
            "/t/[tenantSlug]/locations", "/t/[tenantSlug]/farm-tasks", "/t/[tenantSlug]/trends",
            "/t/[tenantSlug]/news", "/t/[tenantSlug]/farm-risk", "/t/[tenantSlug]/dashboard",
            "/t/[tenantSlug]/notifications",
        ]
        for surface in AppSurface.allCases where !AssistantPageContext.unserved.contains(surface) {
            XCTAssertTrue(served.contains(AssistantPageContext.template(surface)), "\(surface)")
        }
        // A surface the web has no page for sends no context at all.
        XCTAssertNil(AssistantPageContext.surface(.documents))
        XCTAssertFalse(served.contains(AssistantPageContext.template(.documents)), "positive control")
    }

    // MARK: - A turn

    private func store(_ events: [AssistantEvent], throwing: Error? = nil) -> AssistantStore {
        AssistantStore { _ in
            if let throwing { throw throwing }
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func ask(_ store: AssistantStore, _ question: String = "Колко задачи имам?") async {
        store.draft = question
        store.send(context: .surface(.tasks))
        await store.settled()
        XCTAssertFalse(store.asking, "the turn ended")
    }

    func testAnAnswer() async {
        let store = store([.thinking, .toolCall(name: "list_tasks"),
                           .toolResult(name: "list_tasks", ok: true, truncated: false),
                           .answer(text: "Имате 3 текущи задачи.", links: [AssistantLink(route: "/farm-tasks", label: "Задачи")], proposal: nil),
                           .done(truncatedAny: false)])
        await ask(store)
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].question, "Колко задачи имам?")
        XCTAssertEqual(store.turns[0].phase, .answered("Имате 3 текущи задачи.",
                                                      links: [AssistantLink(route: "/farm-tasks", label: "Задачи")], note: nil))
        XCTAssertEqual(store.draft, "", "the question left the field")
    }

    func testARefusalIsSaidInBulgarian() async {
        let store = store([.thinking, .refusal(reason: "ASSISTANT_INPUT_REJECTED", message: nil)])
        await ask(store)
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.refusal("ASSISTANT_INPUT_REJECTED")))
        // The server's own sentence when it is Bulgarian; the copy when it
        // is English (an `en` account): the phone shows no English.
        let bg = self.store([.refusal(reason: "ASSISTANT_OUT_OF_SCOPE", message: "Това е извън данните.")])
        await ask(bg)
        XCTAssertEqual(bg.turns[0].phase, .unanswered("Това е извън данните."))
        let en = self.store([.refusal(reason: "ASSISTANT_OUT_OF_SCOPE", message: "That is out of scope.")])
        await ask(en)
        XCTAssertEqual(en.turns[0].phase, .unanswered(AssistantText.refusal("ASSISTANT_OUT_OF_SCOPE")))
    }

    /// An egress block discards an answer already shown: nothing of it stays.
    func testAnEgressBlockDiscardsTheAnswer() async {
        let store = store([.answer(text: "Ключът е …", links: [], proposal: nil),
                           .refusal(reason: "ASSISTANT_EGRESS_BLOCKED", message: nil)])
        await ask(store)
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.refusal("ASSISTANT_EGRESS_BLOCKED")))
    }

    /// A halt after an answer keeps the answer and says it is incomplete; a
    /// halt before one says why there is none.
    func testAHaltIsIncompleteNotAnError() async {
        let after = store([.answer(text: "Частичен отговор.", links: [], proposal: nil),
                           .halt(outcome: "ASSISTANT_TOOL_BUDGET", message: nil, counts: ["toolCalls": 8, "limit": 8])])
        await ask(after)
        XCTAssertEqual(after.turns[0].phase,
                       .answered("Частичен отговор.", note: AssistantText.halt("ASSISTANT_TOOL_BUDGET")))
        let before = store([.thinking, .halt(outcome: "ASSISTANT_PROVIDER_UNAVAILABLE", message: nil, counts: [:])])
        await ask(before)
        XCTAssertEqual(before.turns[0].phase, .unanswered(AssistantText.halt("ASSISTANT_PROVIDER_UNAVAILABLE")))
    }

    /// Partial and out of time (agri-saas #2648): the halt says the time,
    /// `done` says the partial read, and both are said under the answer.
    /// The partial halt itself is not said twice.
    func testAPartialReadIsSaidEvenWhenTimeEndedTheTurn() async {
        let both = store([.answer(text: "Рискът е нисък.", links: [], proposal: nil),
                          .halt(outcome: "ASSISTANT_TIME_BUDGET", message: nil, counts: [:]),
                          .done(truncatedAny: false, partialAny: true)])
        await ask(both)
        XCTAssertEqual(both.turns[0].phase, .answered("Рискът е нисък.", note:
            AssistantText.halt("ASSISTANT_TIME_BUDGET") + " " + AssistantText.halt("ASSISTANT_PARTIAL_DATA")))

        let once = store([.answer(text: "Рискът е нисък.", links: [], proposal: nil),
                          .halt(outcome: "ASSISTANT_PARTIAL_DATA", message: nil, counts: [:]),
                          .done(truncatedAny: false, partialAny: true)])
        await ask(once)
        XCTAssertEqual(once.turns[0].phase, .answered("Рискът е нисък.", note: AssistantText.halt("ASSISTANT_PARTIAL_DATA")))

        let noHalt = store([.answer(text: "Имате 20 блока.", links: [], proposal: nil),
                            .done(truncatedAny: true, partialAny: false)])
        await ask(noHalt)
        XCTAssertEqual(noHalt.turns[0].phase, .answered("Имате 20 блока.", note: AssistantText.halt("ASSISTANT_TRUNCATED_RESULT")))

        // A halt with no `done` after it ends the turn as the halt said.
        let cut = store([.answer(text: "Частичен.", links: [], proposal: nil),
                         .halt(outcome: "ASSISTANT_TOOL_BUDGET", message: nil, counts: [:])])
        await ask(cut)
        XCTAssertEqual(cut.turns[0].phase, .answered("Частичен.", note: AssistantText.halt("ASSISTANT_TOOL_BUDGET")))
    }

    /// No `refusal`, `halt` or `done`: the transport, and nothing else.
    func testAStreamThatJustEndsIsAnInterruption() async {
        let store = store([.thinking])
        await ask(store)
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.interrupted))
    }

    func testDoneWithNoAnswerSaysSo() async {
        let store = store([.thinking, .done(truncatedAny: false)])
        await ask(store)
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.noAnswer))
    }

    /// Before the stream: 204 is "off"; a coded refusal reads in Bulgarian.
    func testRefusalsBeforeTheStream() async {
        let off = store([], throwing: APIClient.APIError.http(status: 404, code: "NOT_FOUND", message: "Not Found"))
        await ask(off)
        XCTAssertEqual(off.turns[0].phase, .unanswered(AssistantText.switchedOff), "the flag off: no such surface")
        let empty = store([], throwing: APIClient.APIError.http(status: 204, code: nil, message: nil))
        await ask(empty)
        XCTAssertEqual(empty.turns[0].phase, .unanswered(AssistantText.switchedOff))
        // The shared AI budget stop, not a code of the assistant's own.
        let budget = store([], throwing: APIClient.APIError.http(status: 403, code: "AI_BUDGET_EXCEEDED",
                                                                   message: "FREE plan allows 1000 AI tokens per month."))
        await ask(budget)
        XCTAssertEqual(budget.turns[0].phase, .unanswered(UserMessage.bulgarian["AI_BUDGET_EXCEEDED"] ?? "missing"))
    }

    func testOneQuestionAtATime() {
        let store = AssistantStore { _ in AsyncThrowingStream { _ in } }
        XCTAssertFalse(store.canSend, "an empty field")
        store.draft = "   "
        XCTAssertFalse(store.canSend, "blank")
        store.draft = "Колко?"
        XCTAssertTrue(store.canSend)
        store.send(context: nil)
        XCTAssertTrue(store.asking)
        store.draft = "Още?"
        XCTAssertFalse(store.canSend, "the first is still running")
        store.stop()
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.interrupted))
    }

    // MARK: - The stream's patience

    /// The server's heartbeat is every 25 seconds while the model and its
    /// tools work (agri-saas `HEARTBEAT_INTERVAL_MS`). The stream waits two
    /// of them, so a question is not given up on while it is being answered.
    /// It was the ordinary 15, and the owner's question ended in «Сървърът
    /// не отговори навреме.» (2026-11-01).
    func testTheStreamOutwaitsTheServersHeartbeat() {
        let stream = APIClient.streamSessionConfiguration()
        let heartbeat: TimeInterval = 25
        XCTAssertGreaterThanOrEqual(stream.timeoutIntervalForRequest, 2 * heartbeat)
        XCTAssertNil(stream.urlCache, "a stream reaching Cache.db (#134)")
        XCTAssertEqual(APIClient.sessionConfiguration().timeoutIntervalForRequest, 15,
                       "positive control: the ordinary session is unchanged")
        let source = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Agrent/API/APIClient.swift"), encoding: .utf8)
        XCTAssertTrue(source?.contains("try await streamSession.bytes(for: req)") == true,
                      "the stream opens on its own session")
    }

    // MARK: - The wait says what it is doing

    /// Every tool the server has (agri-saas `tools.ts`, 2026-11-01) has its
    /// own Bulgarian sentence, and an unknown one the general sentence.
    func testTheWaitNamesWhatIsBeingRead() {
        let tools = ["list_farm_tasks", "list_journal_entries", "list_blocks", "analyze_block_risk",
                     "grain_calculator", "list_cost_entries", "list_exchange_listings", "price_trends",
                     "propose_activity", "propose_treatment"]
        for tool in tools {
            XCTAssertNotEqual(AssistantText.reading(tool), AssistantText.reading, "\(tool) has no sentence of its own")
            XCTAssertTrue(AssistantText.reading(tool).hasSuffix("…"), tool)
        }
        XCTAssertEqual(AssistantText.reading("something_new"), AssistantText.reading)
    }

    /// A tool call says what it reads; its result says the answer is being
    /// written; the answer replaces both.
    func testTheWaitFollowsTheTurn() async {
        var feed: AsyncThrowingStream<AssistantEvent, Error>.Continuation?
        let store = AssistantStore { _ in
            AsyncThrowingStream { feed = $0 }
        }
        store.draft = "Колко задачи имам?"
        store.send(context: nil)
        func phase(becomes expected: AssistantStore.Turn.Phase) async -> Bool {
            for _ in 0..<100 {
                if store.turns.first?.phase == expected { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        for _ in 0..<100 where feed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        feed?.yield(.toolCall(name: "list_farm_tasks"))
        let reading = await phase(becomes: .working(AssistantText.reading("list_farm_tasks")))
        XCTAssertTrue(reading, "the wait does not name the tasks")
        feed?.yield(.toolResult(name: "list_farm_tasks", ok: true, truncated: false))
        let writing = await phase(becomes: .working(AssistantText.writing))
        XCTAssertTrue(writing, "the wait does not say the answer is being written")
        feed?.yield(.answer(text: "Имате 3 задачи.", links: [], proposal: nil))
        feed?.yield(.done(truncatedAny: false))
        feed?.finish()
        await store.settled()
        XCTAssertEqual(store.turns.first?.phase, .answered("Имате 3 задачи.", note: nil))
    }

    // MARK: - Words

    func testEverySentenceIsBulgarian() {
        var sentences = [AssistantText.intro, AssistantText.noAnswer, AssistantText.interrupted,
                         AssistantText.switchedOff, AssistantText.writing, AssistantText.reading("list_blocks")]
        sentences += ["ASSISTANT_NO_GROUNDING", "ASSISTANT_OUT_OF_SCOPE", "ASSISTANT_HIGH_STAKES_NEEDS_SOURCE",
                      "ASSISTANT_EGRESS_BLOCKED", "ASSISTANT_INPUT_REJECTED", "SOMETHING_NEW"].map(AssistantText.refusal)
        sentences += ["ASSISTANT_TOOL_BUDGET", "ASSISTANT_SPEND_CEILING", "ASSISTANT_TIME_BUDGET",
                      "ASSISTANT_PROVIDER_UNAVAILABLE", "ASSISTANT_TRUNCATED_RESULT", "ASSISTANT_PARTIAL_DATA",
                      "SOMETHING_NEW"]
            .map { AssistantText.halt($0) }
        for code in ["ASSISTANT_QUESTION_INVALID", "ASSISTANT_CONTEXT_INVALID", "AI_BUDGET_EXCEEDED"] {
            sentences.append(UserMessage.bulgarian[code] ?? "missing \(code)")
        }
        for sentence in sentences {
            XCTAssertTrue(UserMessage.isBulgarianSentence(sentence), sentence)
        }
        // agri-saas #2595's catalogue, word for word: the copy is never a
        // second wording of what the server says.
        XCTAssertEqual(AssistantText.refusal("ASSISTANT_NO_GROUNDING"),
                       "Не намерих нищо в данните на стопанството, с което да отговоря, и няма да предполагам.")
        XCTAssertEqual(AssistantText.halt("ASSISTANT_PROVIDER_UNAVAILABLE"),
                       "Не успях да се свържа с модела. Данните на стопанството не бяха прочетени и нищо не беше създадено.")
        XCTAssertEqual(AssistantText.halt("ASSISTANT_PARTIAL_DATA"),
                       "Отговорът по-горе е непълен — част от Вашите записи не можаха да бъдат включени, "
                       + "така че го приемете като частична картина.", "agri-saas #2648's own words")
        XCTAssertNotEqual(AssistantText.halt("ASSISTANT_PARTIAL_DATA"), AssistantText.halt("SOMETHING_NEW"))
        XCTAssertFalse(AssistantText.halt("ASSISTANT_PROVIDER_UNAVAILABLE").contains("непълен"),
                       "an outage can come before any answer, and does not call one incomplete")
    }

    /// The answer's Markdown kept, its links kept as words: a web page path
    /// opens nothing in the app.
    func testLinksAreKeptAsWords() {
        let rendered = AssistantRendering.answer("Вижте **Задачи** в [Дневника](/journal).")
        XCTAssertEqual(String(rendered.characters), "Вижте Задачи в Дневника.")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }

    // MARK: - The button's room

    func testTheButtonClearsTheBarsOnScreen() {
        let chrome = BottomChrome()
        let gold = UUID(), undo = UUID()
        XCTAssertEqual(chrome.height, 0)
        chrome.report(gold, 76)
        chrome.report(undo, 48)
        XCTAssertEqual(chrome.height, 124, "the «Отмени» bar sits above the gold button")
        chrome.withdraw(undo)
        XCTAssertEqual(chrome.height, 76)
        chrome.report(gold, 80)
        XCTAssertEqual(chrome.height, 80, "a bar that grew is reported once, not twice")
    }

    func testTheFlagIsTheServers() {
        XCTAssertEqual(AssistantAPI.flag, "assistant.enabled")
        XCTAssertTrue(AssistantAPI.streamPath.hasSuffix("/assistant/stream"))
    }
}
