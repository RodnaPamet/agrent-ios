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

    // MARK: - The two nullable fields the spec declares and this model did not

    /// `FarmTaskListItem.key` and `.severity` are both `["string","null"]` in
    /// the generated spec. Declared non-optional here, a single null threw —
    /// and because the list decodes an ARRAY, one row would have taken the
    /// whole Задачи tab with it, on a payload the server considers valid.
    ///
    /// The comment on `key` said "Non-null on every row measured", which was
    /// true of the eight rows that existed and is not what the contract says.
    func testARowWithANullKeyAndNullSeverityStillDecodes() async throws {
        let row = try await APIClient.shared.decode(Data(#"""
        {"id":"t1","key":null,"title":"Пръскане","type":"FIELD_OPERATION",
         "status":"OPEN","severity":null,"dueAt":null,"assignee":null,
         "assigneeUserId":null,"createdAt":"2026-09-01T10:00:00.000Z",
         "updatedAt":"2026-09-01T10:00:00.000Z"}
        """#.utf8), as: WorkItemSummary.self)

        XCTAssertNil(row.key)
        XCTAssertEqual(row.severity, .unknown)
    }

    /// THE one that matters: a whole list must survive one such row. This is
    /// the blast radius the old declaration had, not the missing label.
    func testOneNullRowDoesNotTakeTheWholeListWithIt() async throws {
        let rows = try await APIClient.shared.decode(Data(#"""
        [{"id":"a","key":"AGT-1","title":"Едно","type":"FIELD_OPERATION",
          "status":"OPEN","severity":"HIGH","dueAt":null,"assignee":null,
          "assigneeUserId":null,"createdAt":"2026-09-01T10:00:00.000Z",
          "updatedAt":"2026-09-01T10:00:00.000Z"},
         {"id":"b","key":null,"title":"Две","type":"FIELD_OPERATION",
          "status":"OPEN","severity":null,"dueAt":null,"assignee":null,
          "assigneeUserId":null,"createdAt":"2026-09-01T10:00:00.000Z",
          "updatedAt":"2026-09-01T10:00:00.000Z"}]
        """#.utf8), as: [WorkItemSummary].self)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].severity, .high)
        XCTAssertEqual(rows[1].severity, .unknown)
    }

    /// `LenientDecodable` looks like it already covered a null severity and
    /// did not: it is lenient about an unrecognised STRING, decoded through a
    /// single-value container that throws on null. Both paths now land on
    /// `.unknown`, which is what the case was for.
    func testAnUnrecognisedSeverityAndANullOneBothLandOnUnknown() async throws {
        func severity(_ value: String) async throws -> WorkItemSeverity {
            try await APIClient.shared.decode(Data(#"""
            {"id":"t","key":"AGT-9","title":"Т","type":"FIELD_OPERATION",
             "status":"OPEN","severity":\#(value),"dueAt":null,"assignee":null,
             "assigneeUserId":null,"createdAt":"2026-09-01T10:00:00.000Z",
             "updatedAt":"2026-09-01T10:00:00.000Z"}
            """#.utf8), as: WorkItemSummary.self).severity
        }
        let fromNull = try await severity("null")
        let fromNonsense = try await severity(#""CATASTROPHIC""#)
        XCTAssertEqual(fromNull, .unknown)
        XCTAssertEqual(fromNonsense, .unknown)
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
