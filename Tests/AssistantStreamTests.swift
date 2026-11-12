import XCTest
@testable import Agrent

/// The answer as it streams (#587; agri-saas #2670 item 4), against the shape
/// backend 1 sent on 2026-11-12: `answer_delta` {text, seq, restarted?}
/// before the whole `answer`. Synthetic text; nothing is asked of a server.
@MainActor
final class AssistantStreamTests: XCTestCase {

    // MARK: - The parts

    func testPartsAppendInOrder() {
        var stream = AssistantStream()
        stream.apply("Поливайте рано сутрин. ", seq: 0, restarted: false)
        stream.apply("Избягвайте обяд. ", seq: 1, restarted: false)
        XCTAssertEqual(stream.text, "Поливайте рано сутрин. Избягвайте обяд. ")
        XCTAssertFalse(stream.stalled)
    }

    /// A gap is a LOST part: what is shown stays, nothing more is added.
    func testAGapStopsAddingRatherThanDrawAHole() {
        var stream = AssistantStream()
        stream.apply("Първо. ", seq: 0, restarted: false)
        stream.apply("Трето. ", seq: 2, restarted: false)
        XCTAssertTrue(stream.stalled)
        stream.apply("Четвърто. ", seq: 3, restarted: false)
        XCTAssertEqual(stream.text, "Първо. ", "a part after the gap was added")
    }

    /// A restart means what is shown is WRONG: replaced, and counted from.
    func testARestartReplacesEverything() {
        var stream = AssistantStream()
        stream.apply("Ще проверя задачите. ", seq: 0, restarted: false)
        stream.apply("Отначало. ", seq: 1, restarted: true)
        XCTAssertEqual(stream.text, "Отначало. ")
        stream.apply("Продължение. ", seq: 2, restarted: false)
        XCTAssertEqual(stream.text, "Отначало. Продължение. ")
        // And it clears a stall: the restart is a new beginning.
        var stalled = AssistantStream()
        stalled.apply("А. ", seq: 0, restarted: false)
        stalled.apply("В. ", seq: 5, restarted: false)
        stalled.apply("Ново. ", seq: 0, restarted: true)
        XCTAssertFalse(stalled.stalled)
        XCTAssertEqual(stalled.text, "Ново. ")
    }

    // MARK: - What may be drawn

    /// The server's own examples of a sentence ending mid-Markdown.
    func testUnfinishedMarkdownIsHeldBack() {
        XCTAssertEqual(AssistantStream.visible("Това е **важно. "), "Това е ")
        XCTAssertEqual(AssistantStream.visible("Това е **важно**. "), "Това е **важно**. ", "closed bold is shown")
        XCTAssertEqual(AssistantStream.visible("Ред 1.\n| Поле | Площ. |"), "Ред 1.\n", "a table row waits for its line")
        XCTAssertEqual(AssistantStream.visible("| Поле | Площ |\n"), "| Поле | Площ |\n", "a whole row is shown")
        XCTAssertEqual(AssistantStream.visible("Код `abc. "), "Код ")
        XCTAssertEqual(AssistantStream.visible("1. Първо. "), "1. Първо. ", "a list item is fine on its own")
        XCTAssertEqual(AssistantStream.visible("**Заглавие**\nТекст с **удебеляване. "),
                       "**Заглавие**\nТекст с ", "only the last line is trimmed")
    }

    // MARK: - The event

    func testTheEventDecodes() async throws {
        func decode(_ json: String) async throws -> AssistantEvent {
            try await APIClient.shared.decode(Data(json.utf8), as: AssistantEvent.self)
        }
        let plain = try await decode(#"{"type":"answer_delta","text":"Здравейте. ","seq":0}"#)
        XCTAssertEqual(plain, .answerDelta(text: "Здравейте. ", seq: 0, restarted: false))
        let again = try await decode(#"{"type":"answer_delta","text":"Отново. ","seq":3,"restarted":true}"#)
        XCTAssertEqual(again, .answerDelta(text: "Отново. ", seq: 3, restarted: true))
        let noSeq = try await decode(#"{"type":"answer_delta","text":"Без номер. "}"#)
        XCTAssertEqual(noSeq, .unknown(type: "answer_delta"), "a part it cannot place is skipped")
        XCTAssertFalse(plain.ends)
    }

    // MARK: - A turn

    private func store(_ events: [AssistantEvent]) -> AssistantStore {
        AssistantStore { _ in
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func ask(_ store: AssistantStore) async {
        store.draft = "Кога да поливам?"
        store.send(context: nil)
        await store.settled()
    }

    /// The whole answer replaces the parts, a duplicate from a retry included.
    func testTheAnswerReplacesTheParts() async {
        let store = store([.answerDelta(text: "Поливайте рано сутрин. ", seq: 0),
                           .answerDelta(text: "Поливайте рано сутрин. ", seq: 0, restarted: true),
                           .answer(text: "Поливайте рано сутрин. Готово.", links: [], proposal: nil),
                           .done(truncatedAny: false)])
        await ask(store)
        XCTAssertEqual(store.turns[0].phase, .answered("Поливайте рано сутрин. Готово.", note: nil))
    }

    /// A refusal after parts were shown discards them (backend 1: discard,
    /// never redact).
    func testARefusalDiscardsWhatStreamed() async {
        let store = store([.answerDelta(text: "Ключът е ", seq: 0),
                           .refusal(reason: "ASSISTANT_EGRESS_REFUSED", message: nil)])
        await ask(store)
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.refusal("ASSISTANT_EGRESS_REFUSED")))
    }

    /// A halt keeps what was released, with the halt's note.
    func testAHaltKeepsWhatStreamed() async {
        let store = store([.answerDelta(text: "Първата част. ", seq: 0),
                           .halt(outcome: "ASSISTANT_TIME_BUDGET", message: nil),
                           .done(truncatedAny: false)])
        await ask(store)
        guard case .answered(let text, _, let note, _, _) = store.turns[0].phase else {
            return XCTFail("the streamed part was lost: \(store.turns[0].phase)")
        }
        XCTAssertEqual(text, "Първата част. ")
        XCTAssertNotNil(note)
    }

    /// While parts arrive the turn shows them, and «Спри» ends it as any
    /// running turn.
    func testTheTurnShowsThePartsAsTheyCome() async throws {
        let (events, continuation) = AsyncThrowingStream<AssistantEvent, Error>.makeStream()
        let store = AssistantStore { _ in events }
        store.draft = "Кога да поливам?"
        store.send(context: nil)
        continuation.yield(.answerDelta(text: "Рано сутрин. ", seq: 0))
        continuation.yield(.answerDelta(text: "Не на **обяд. ", seq: 1))
        for _ in 0..<200 where store.turns.first?.phase != .streaming("Рано сутрин. Не на ") {
            await Task.yield()
        }
        XCTAssertEqual(store.turns.first?.phase, .streaming("Рано сутрин. Не на "), "the open bold was drawn")
        XCTAssertTrue(store.turns[0].isWorking)
        store.stop()
        XCTAssertEqual(store.turns[0].phase, .unanswered(AssistantText.interrupted))
        continuation.finish()
    }
}
