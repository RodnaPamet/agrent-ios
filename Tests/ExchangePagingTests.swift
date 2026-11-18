import XCTest
@testable import Agrent

/// #673 — «Покажи още» continues the question that produced the list on
/// screen, and an answer to a superseded question is dropped.
///
/// `query` is bound live to the search field and only asked on submit, so it
/// can hold a term nobody searched for. Paging used to build the next request
/// from it with the on-screen list's cursor, appending the new term's rows to
/// the old term's list.
final class ExchangePagingTests: XCTestCase {

    func testTheNextPageContinuesTheShownQuestionNotTheLiveField() {
        var shown = ExchangeQuery()
        shown.text = "пшеница"
        // The field now holds an unsubmitted term — irrelevant to paging.
        var live = shown
        live.text = "царевица"

        let next = ExchangeListingsStore.nextPage(shown: shown, cursor: "c-2")
        XCTAssertEqual(next?.text, "пшеница")
        XCTAssertEqual(next?.cursor, "c-2")
        XCTAssertNotEqual(next?.text, live.text, "control: the live term differs")
    }

    func testNothingToContinueWithoutAShownListOrACursor() {
        XCTAssertNil(ExchangeListingsStore.nextPage(shown: nil, cursor: "c-2"))
        XCTAssertNil(ExchangeListingsStore.nextPage(shown: ExchangeQuery(), cursor: nil))
    }

    func testAnAnswerToASupersededQuestionIsNotCurrent() {
        var first = ExchangeQuery()
        first.regions = ["BG-15"]
        var second = ExchangeQuery()
        second.regions = ["BG-15", "BG-03"]

        // The slower first answer lands after the second was asked.
        XCTAssertFalse(ExchangeListingsStore.isCurrent(asked: first, latest: second))
        XCTAssertTrue(ExchangeListingsStore.isCurrent(asked: second, latest: second))
        XCTAssertFalse(ExchangeListingsStore.isCurrent(asked: first, latest: nil))
    }

    /// The store wires both helpers in: paging reads `shownQuery`, never
    /// `query`, and `apply` consults `isCurrent` before touching the list.
    func testTheStoreUsesBoth() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/Exchange/ExchangeStores.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("final class ExchangeListingsStore"), "positive control")
        XCTAssertTrue(s.contains("Self.nextPage(shown: shown, cursor: nextCursor)"))
        XCTAssertFalse(s.contains("var next = query"), "paging must not start from the live query")
        XCTAssertTrue(s.contains("guard Self.isCurrent(asked: asked, latest: lastAsked) else { return }"))
    }
}
