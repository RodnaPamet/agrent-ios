import XCTest
@testable import Agrent

/// Each task row's date (owner, 2026-10-09, #236): «Завършена на» once the
/// task is complete and the list says when, «Отворена на» otherwise — and
/// never another date passed off as the completion.
final class TaskRowDateTests: XCTestCase {

    /// Mid-day, so no zone the suite runs in moves these days across midnight.
    private let now = BgDate.parseInstant("2026-10-09T12:00:00.000Z")!

    private func row(_ status: String, createdAt: String? = "2026-09-20T12:00:00.000Z",
                     completedAt: String? = nil) throws -> WorkItemSummary {
        var fields = [#""id":"wi_1""#, #""title":"T""#, #""type":"TASK""#, #""status":"\#(status)""#,
                      // A later edit's date: it must never stand in for a completion.
                      #""updatedAt":"2026-10-05T12:00:00.000Z""#]
        if let createdAt { fields.append(#""createdAt":"\#(createdAt)""#) }
        if let completedAt { fields.append(#""completedAt":"\#(completedAt)""#) }
        return try APIClientTestDecoder.decode(WorkItemSummary.self, from: "{\(fields.joined(separator: ","))}")
    }

    func testAnOpenTaskSaysWhenItWasOpened() throws {
        XCTAssertEqual(try row("OPEN").rowDate(now: now), "Отворена на 20 септември")
        XCTAssertEqual(try row("IN_PROGRESS").rowDate(now: now), "Отворена на 20 септември")
    }

    /// The list will send `completedAt` once agri-saas adds it; a complete
    /// task then says when it was completed — CLOSED, and RESOLVED with it.
    func testACompletedTaskSaysWhenItWasCompleted() throws {
        XCTAssertEqual(try row("CLOSED", completedAt: "2026-10-08T12:00:00.000Z").rowDate(now: now),
                       "Завършена на 8 октомври")
        XCTAssertEqual(try row("RESOLVED", completedAt: "2026-10-08T12:00:00.000Z").rowDate(now: now),
                       "Завършена на 8 октомври")
    }

    /// Today's list, which has no `completedAt`: the opened date, said as
    /// such — not `updatedAt` («5 октомври») worded as a completion.
    func testWithoutTheCompletionDateItSaysWhenItWasOpened() throws {
        let said = try row("CLOSED").rowDate(now: now)
        XCTAssertEqual(said, "Отворена на 20 септември")
        XCTAssertFalse(said?.contains("5 октомври") ?? true)
    }

    /// A canceled task was not completed, whatever date it carries.
    func testACanceledTaskIsNotCalledCompleted() throws {
        XCTAssertEqual(try row("CANCELED", completedAt: "2026-10-08T12:00:00.000Z").rowDate(now: now),
                       "Отворена на 20 септември")
    }

    func testNoDateMeansNoLine() throws {
        XCTAssertNil(try row("OPEN", createdAt: nil).rowDate(now: now))
    }

    /// The year only when it is not this one — a task from last autumn must
    /// not read as this year's.
    func testAnotherYearsDateCarriesItsYear() throws {
        let said = try row("OPEN", createdAt: "2025-11-03T12:00:00.000Z").rowDate(now: now)
        let opened = BgDate.parseInstant("2025-11-03T12:00:00.000Z")!
        XCTAssertEqual(said, "Отворена на \(BgDate.full(opened))")
        XCTAssertTrue(said?.contains("2025") ?? false, said ?? "nil")
        // Positive control: this year's has none.
        XCTAssertFalse(BgDate.rowDay(BgDate.parseInstant("2026-03-03T12:00:00.000Z")!, now: now).contains("2026"))
    }
}
