import XCTest
@testable import Agrent

/// The list route sends a PROJECTION, and this suite exists because a model
/// built from the full field list failed the whole list on the device.
///
/// The shape below is the one production actually returned on 2026-09-22 —
/// eleven keys, taken as a UNION across all eight rows rather than from the
/// first, since `dueAt` and `assignee` are null on some of them and reading
/// one row would have missed whichever keys it happened not to carry.
///
/// Names and addresses here are invented. The real rows carry real people.
final class WorkItemSummaryTests: XCTestCase {

    /// Exactly the keys the route sends. Nothing added, nothing removed.
    private let measuredRow = #"""
    {"id":"wi_1","key":"AGT-104","title":"Spray — South block",
     "type":"FIELD_OPERATION","status":"OPEN","severity":"MEDIUM",
     "dueAt":null,"assignee":null,"assigneeUserId":null,
     "createdAt":"2026-09-18T07:12:00.000Z","updatedAt":"2026-09-20T09:30:00.000Z"}
    """#

    private func decode(_ json: String) throws -> WorkItemSummary {
        try APIClientTestDecoder.decode(WorkItemSummary.self, from: json)
    }

    /// THE regression. `WorkItem` requires `tenantId` and `priority`; the
    /// list sends neither, so decoding the list as `WorkItem` lost all eight
    /// rows to `keyNotFound` on the first one.
    func testTheMeasuredRowDecodes() throws {
        let row = try decode(measuredRow)
        XCTAssertEqual(row.id, "wi_1")
        XCTAssertEqual(row.key, "AGT-104")
        XCTAssertEqual(row.type, .fieldOperation)
        XCTAssertEqual(row.status, .open)
        XCTAssertNil(row.dueAt)
        XCTAssertNil(row.assignee)
    }

    /// And the projection must NOT be decodable as the full type — if it
    /// ever becomes so, the two have converged and this file is obsolete.
    /// Better to be told than to keep a stale distinction.
    func testTheListRowIsStillNotAWholeWorkItem() {
        XCTAssertThrowsError(
            try APIClientTestDecoder.decode(WorkItem.self, from: measuredRow),
            "the list projection now decodes as a full WorkItem — has the route changed?"
        )
    }

    func testAnAssigneeDecodesWhenPresent() throws {
        let json = #"""
        {"id":"wi_2","key":"AGT-105","title":"Fertilize — North block",
         "type":"FARM_TASK","status":"RESOLVED","severity":"LOW","dueAt":null,
         "assignee":{"id":"u_7","name":"Иван Петров","email":"ivan@example.invalid"},
         "assigneeUserId":"u_7","createdAt":"2026-09-18T07:12:00.000Z",
         "updatedAt":"2026-09-20T09:30:00.000Z"}
        """#
        let row = try decode(json)
        XCTAssertEqual(row.assignee?.displayName, "Иван Петров")
        XCTAssertEqual(row.assigneeUserId, "u_7")
    }

    /// An assignee with no name falls back to the address, and one with
    /// neither shows nothing — an empty space beats the word "Unknown" in
    /// English on a Bulgarian screen.
    func testDisplayNameFallsBackAndThenGivesUp() {
        typealias A = WorkItemSummary.Assignee
        XCTAssertEqual(A(id: "u", name: "Иван", email: "i@x.invalid").displayName, "Иван")
        XCTAssertEqual(A(id: "u", name: nil, email: "i@x.invalid").displayName, "i@x.invalid")
        XCTAssertEqual(A(id: "u", name: "", email: "i@x.invalid").displayName, "i@x.invalid")
        XCTAssertNil(A(id: "u", name: nil, email: nil).displayName)
        XCTAssertNil(A(id: "u", name: "", email: "").displayName)
    }

    /// `dueAt` is null on every production row today, so overdue is
    /// MODELLED, NOT VERIFIED against real data. These pin the intent so the
    /// first task with a real deadline finds the logic already decided.
    func testOverdueNeedsAPastDateAndUnfinishedWork() throws {
        func row(due: String, status: String) -> String {
            #"""
            {"id":"w","key":"K","title":"t","type":"TASK","status":"\#(status)",
             "severity":"LOW","dueAt":"\#(due)","assignee":null,
             "assigneeUserId":null,"createdAt":"2026-01-01T00:00:00.000Z",
             "updatedAt":"2026-01-01T00:00:00.000Z"}
            """#
        }
        XCTAssertTrue(try decode(row(due: "2020-01-01T00:00:00.000Z", status: "OPEN")).isOverdue)
        // Finished work is not overdue, however late it was — telling someone
        // a completed job is late is worse than saying nothing.
        XCTAssertFalse(try decode(row(due: "2020-01-01T00:00:00.000Z", status: "RESOLVED")).isOverdue)
        XCTAssertFalse(try decode(row(due: "2020-01-01T00:00:00.000Z", status: "CANCELED")).isOverdue)
        XCTAssertFalse(try decode(row(due: "2099-01-01T00:00:00.000Z", status: "OPEN")).isOverdue)
    }

    /// The whole envelope as the route sends it: `{rows, truncated}`,
    /// measured, with `truncated` present and false.
    func testTheMeasuredEnvelopeDecodes() async throws {
        let json = #"{"rows":[\#(measuredRow)],"truncated":false}"#
        let page = try await WorkItemAPI.decodeList(from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertFalse(page.truncated)
    }

    func testTruncationReachesTheScreenLayer() async throws {
        let json = #"{"rows":[\#(measuredRow)],"truncated":true}"#
        let page = try await WorkItemAPI.decodeList(from: Data(json.utf8))
        XCTAssertTrue(page.truncated)
    }
}

/// Decodes with the app's own date strategy, so a test cannot pass against a
/// formatter the app does not use.
enum APIClientTestDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = withFraction.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(text)"))
            }
            return date
        }
        return try d.decode(T.self, from: Data(json.utf8))
    }
}
