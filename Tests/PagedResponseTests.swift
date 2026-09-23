import XCTest
@testable import Agrent

/// `/tasks` answers `{rows, truncated}` without pagination and
/// `{items, pageInfo}` with it — same route, two keys. `/journal` splits the
/// same way and keys its paginated branch `rows`, so the rule you would
/// derive from either one is wrong on the other.
final class PagedResponseTests: XCTestCase {

    private struct Row: Decodable, Sendable, Equatable {
        let id: String
    }

    private func decode(_ json: String) throws -> PagedResponse<Row> {
        try JSONDecoder().decode(PagedResponse<Row>.self, from: Data(json.utf8))
    }

    // MARK: - Both branches

    func testUnpaginatedBranchUsesRows() throws {
        let page = try decode(#"{"rows":[{"id":"a"},{"id":"b"}],"truncated":false}"#)
        XCTAssertEqual(page.items, [Row(id: "a"), Row(id: "b")])
        XCTAssertEqual(page.collectionKey, "rows")
        XCTAssertFalse(page.truncated)
    }

    func testPaginatedBranchUsesItems() throws {
        let page = try decode(#"""
        {"items":[{"id":"a"}],"pageInfo":{"hasNextPage":true,"endCursor":"c1","totalCount":97}}
        """#)
        XCTAssertEqual(page.items, [Row(id: "a")])
        XCTAssertEqual(page.collectionKey, "items")
        XCTAssertEqual(page.pageInfo?.hasNextPage, true)
        XCTAssertEqual(page.pageInfo?.endCursor, "c1")
        XCTAssertEqual(page.pageInfo?.totalCount, 97)
    }

    /// The journal's paginated branch, which is `rows` + `nextCursor`. Same
    /// type, opposite key from tasks' paginated branch — the reason this is
    /// one decoder and not a rule applied from memory.
    func testJournalStylePaginatedBranchAlsoDecodes() throws {
        let page = try decode(#"{"rows":[{"id":"a"}],"nextCursor":"abc"}"#)
        XCTAssertEqual(page.items, [Row(id: "a")])
        XCTAssertEqual(page.nextCursor, "abc")
    }

    // MARK: - The trap

    /// THE test. An absent collection must throw, not yield an empty page.
    ///
    /// The failure this prevents does not happen when the decoder is
    /// written. It happens when someone adds `?limit` later, the server
    /// switches branches, and a screen shows "no tasks" over a tenant with
    /// hundreds — silently, because an empty list is a legitimate answer.
    func testNeitherKeyThrowsRatherThanReturningEmpty() {
        XCTAssertThrowsError(try decode(#"{"truncated":false}"#)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertThrowsError(try decode("{}"))
    }

    /// A genuinely empty list is NOT the same thing and must still decode.
    /// If this throws, the trap detector has become the bug.
    func testAnEmptyCollectionIsStillValid() throws {
        XCTAssertTrue(try decode(#"{"rows":[]}"#).items.isEmpty)
        XCTAssertTrue(try decode(#"{"items":[]}"#).items.isEmpty)
    }

    /// A malformed ELEMENT must report itself, not be reported as a missing
    /// collection. `try? rows` with a fallback to `items` would swallow the
    /// real error and raise the far more alarming wrong one, sending the
    /// next person to look at pagination instead of at the element.
    func testABadElementReportsTheElementNotTheKey() {
        XCTAssertThrowsError(try decode(#"{"rows":[{"id":42}]}"#)) { error in
            if case DecodingError.keyNotFound = error {
                XCTFail("reported as a missing collection: \(error)")
            }
        }
    }

    // MARK: - Truncation

    /// A silently-short list is the same defect as an empty one, and worse
    /// to spot: a truncated list looks exactly like a complete short one.
    func testTruncationIsSurfacedNotSwallowed() throws {
        XCTAssertTrue(try decode(#"{"rows":[{"id":"a"}],"truncated":true}"#).truncated)
    }

    /// Absent `truncated` means not truncated. The paginated branch omits it
    /// entirely, and defaulting to true there would put a warning on every
    /// paged screen forever.
    func testAbsentTruncationDefaultsToFalse() throws {
        XCTAssertFalse(try decode(#"{"items":[{"id":"a"}]}"#).truncated)
    }

    /// Not expected from any endpoint we know. If the server starts sending
    /// both, that is a change nobody told us about, and the key records it
    /// rather than one being picked silently.
    func testBothKeysPresentIsRecorded() throws {
        let page = try decode(#"{"rows":[{"id":"a"}],"items":[{"id":"b"}]}"#)
        XCTAssertEqual(page.items, [Row(id: "a")])
        XCTAssertEqual(page.collectionKey, "rows+items")
    }
}

/// The journal is the first real consumer, and the only one that can be
/// exercised against production data today. These pin the shape the live
/// route actually sends.
final class JournalDecodeShapeTests: XCTestCase {

    private let entry = #"""
    {"id":"e1","type":"ACTIVITY","status":"DONE","title":"Two",
     "notes":null,"occurredAt":"2026-09-11T00:00:00.000Z","version":1}
    """#

    func testLiveEnvelopeShapeDecodes() async throws {
        let json = #"{"rows":[\#(entry)],"nextCursor":null}"#
        let rows = try await JournalAPI.decodeList(from: Data(json.utf8)).entries
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Two")
    }

    /// The no-`limit` branch. `listPath` sends `limit` today, but the cache
    /// holds bytes written by whatever the app asked for at the time.
    func testBareArrayStillDecodes() async throws {
        let rows = try await JournalAPI.decodeList(from: Data("[\(entry)]".utf8)).entries
        XCTAssertEqual(rows.count, 1)
    }

    /// Pretty-printed or newline-led payloads must still be recognised — the
    /// shape is chosen by the first non-whitespace byte, not the first byte.
    func testLeadingWhitespaceDoesNotChangeTheShapeDecision() async throws {
        let rows = try await JournalAPI.decodeList(from: Data("\n  [\(entry)]".utf8)).entries
        XCTAssertEqual(rows.count, 1)
    }

    /// A malformed ENTRY must surface as an entry problem. The old
    /// `catch is DecodingError` fallback reported it as "not an envelope"
    /// and sent the reader to look at pagination.
    func testABadEntryIsNotReportedAsAShapeProblem() async {
        let json = #"{"rows":[{"id":"e1","type":"ACTIVITY","status":"DONE","title":"x","occurredAt":"not-a-date"}]}"#
        do {
            _ = try await JournalAPI.decodeList(from: Data(json.utf8)).entries
            XCTFail("should not decode")
        } catch let error as DecodingError {
            if case .keyNotFound = error {
                XCTFail("reported as a missing collection: \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// An unknown `type` NO LONGER fails the list — changed deliberately on
    /// 2026-09-23, and this is the second of two tests that pinned the old
    /// behaviour. It said "until LenientEnum is applied to it", which is
    /// exactly what happened; see `LogEntryType`'s header for the asymmetry
    /// argument.
    ///
    /// Kept rather than deleted, and pointed the other way, because the
    /// valuable half was never the throw. It was the assertion that this
    /// app has a defined answer for a value the server may add without
    /// telling it.
    func testAnUnknownTypeNoLongerFailsTheList() async throws {
        let json = #"{"rows":[{"id":"e1","type":"BRAND_NEW","status":"DONE","title":"x","occurredAt":"2026-09-11T00:00:00.000Z"}]}"#
        let entries = try await JournalAPI.decodeList(from: Data(json.utf8)).entries
        XCTAssertEqual(entries.count, 1, "the row survived")
        XCTAssertEqual(entries.first?.type, .unknown)
        XCTAssertEqual(entries.first?.title, "x", "its real content is intact")
    }

    /// The distinction that makes the change safe: leniency is for the ENUM
    /// only. A malformed date is still a hard failure, because a journal
    /// entry with no reliable date is not a record that can be filed — and
    /// degrading everything would be the lazy version of this decision.
    func testLeniencyDidNotSpreadToTheRestOfTheRow() async {
        let json = #"{"rows":[{"id":"e1","type":"ACTIVITY","status":"DONE","title":"x","occurredAt":"not-a-date"}]}"#
        do {
            _ = try await JournalAPI.decodeList(from: Data(json.utf8)).entries
            XCTFail("a bad date decoded")
        } catch {}
    }
}
