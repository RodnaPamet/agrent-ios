import XCTest
@testable import Agrent

/// `LogEntryType` shipped SIX cases against the server's TEN and survived
/// only because the live tenant happened to hold two of them. These pin the
/// counts, so a server enum growing shows up here rather than on a screen.
final class WorkItemEnumTests: XCTestCase {

    /// Counted against the server's enum definitions, not recalled. The
    /// `unknown` sentinel is this client's own, so every count is +1.
    func testEveryEnumHasTheCountTheServerDeclares() {
        XCTAssertEqual(WorkItemType.allCases.count, 4 + 1)
        XCTAssertEqual(WorkItemSeverity.allCases.count, 5 + 1)
        XCTAssertEqual(WorkItemPriority.allCases.count, 4 + 1)
        XCTAssertEqual(WorkItemStatus.allCases.count, 8 + 1)
        XCTAssertEqual(WorkItemSource.allCases.count, 5 + 1)
        XCTAssertEqual(FieldOperationType.allCases.count, 4 + 1)
    }

    func testEveryServerValueDecodesToItsOwnCase() throws {
        func check<T: LenientDecodable & Equatable>(_ raws: [String], _ type: T.Type) throws {
            for raw in raws {
                let decoded = try JSONDecoder().decode(T.self, from: Data("\"\(raw)\"".utf8))
                XCTAssertEqual(decoded.rawValue, raw, "\(raw) fell through to unknown")
                XCTAssertNotEqual(decoded, T.unknownCase, "\(raw) fell through to unknown")
            }
        }
        try check(["IMPROVEMENT", "TASK", "FIELD_OPERATION", "FARM_TASK"], WorkItemType.self)
        try check(["INFO", "LOW", "MEDIUM", "HIGH", "CRITICAL"], WorkItemSeverity.self)
        try check(["P0", "P1", "P2", "P3"], WorkItemPriority.self)
        try check(
            ["OPEN", "TRIAGED", "IN_PROGRESS", "BLOCKED", "PENDING_REVIEW",
             "RESOLVED", "CLOSED", "CANCELED"], WorkItemStatus.self)
        try check(["MANUAL", "TEMPLATE", "POLICY_REVIEW", "AUDIT", "INTEGRATION"], WorkItemSource.self)
        try check(["SPRAY", "FERTILIZE", "SEED", "OTHER"], FieldOperationType.self)
    }

    /// The asymmetry these enums exist for: a case added server-side costs a
    /// vague label on one field, never the screen. `LogEntryType` would have
    /// lost every row.
    func testAnUnknownValueCostsOneFieldNotTheList() throws {
        let status = try JSONDecoder().decode(
            WorkItemStatus.self, from: Data("\"DEFERRED_PENDING_WEATHER\"".utf8))
        XCTAssertEqual(status, .unknown)
        XCTAssertEqual(status.label, "—")
    }

    /// `taskEnums.status`, NOT `agStatus.operation`. The server carries two
    /// Bulgarian vocabularies for these same codes, and a phone saying
    /// "Готова" where the web says "Разрешена" for one row is worse than
    /// either being wrong — the operator cannot tell it is the same record.
    func testStatusUsesTheTaskVocabularyNotTheOperationsOne() {
        XCTAssertEqual(WorkItemStatus.resolved.label, "Готова")
        XCTAssertEqual(WorkItemStatus.triaged.label, "Планирана")
        XCTAssertEqual(WorkItemStatus.canceled.label, "Отказана")
        for wrong in ["Разрешена", "Приоритизирана", "Отменена"] {
            XCTAssertFalse(
                WorkItemStatus.allCases.map(\.label).contains(wrong),
                "\(wrong) is the operations vocabulary and has leaked in"
            )
        }
    }

    /// Every case an operator can see must have a Bulgarian label. A missing
    /// one shows as an empty cell, which reads as absent data.
    func testEveryVisibleLabelIsBulgarian() {
        let labels = WorkItemType.allCases.map(\.label)
            + WorkItemSeverity.allCases.map(\.label)
            + WorkItemPriority.allCases.map(\.label)
            + WorkItemStatus.allCases.map(\.label)
            + FieldOperationType.allCases.map(\.label)
        for label in labels {
            XCTAssertFalse(label.isEmpty)
            guard label != "—" else { continue }
            XCTAssertTrue(
                label.unicodeScalars.contains { $0.value > 0x400 },
                "\(label) is not Bulgarian"
            )
        }
    }

    func testFinishedStatusesAreExactlyTheThreeTerminalOnes() {
        XCTAssertEqual(
            Set(WorkItemStatus.allCases.filter(\.isFinished)),
            [.resolved, .closed, .canceled]
        )
    }
}

final class WorkItemDecodeTests: XCTestCase {

    private let minimal = #"""
    {"id":"w1","tenantId":"t1","type":"TASK","title":"Пръскане на южния блок",
     "severity":"MEDIUM","priority":"P2","status":"OPEN","createdByUserId":"u1"}
    """#

    private func decode(_ json: String) throws -> WorkItem {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(WorkItem.self, from: Data(json.utf8))
    }

    /// Everything the server marks optional must actually be optional. A
    /// required field that the server omits fails the whole list.
    func testDecodesWithOnlyTheNonOptionalFields() throws {
        let item = try decode(minimal)
        XCTAssertEqual(item.title, "Пръскане на южния блок")
        XCTAssertNil(item.description)
        XCTAssertNil(item.dueAt)
        XCTAssertNil(item.source)
        XCTAssertNil(item.operationType)
    }

    /// `description` and `resolution` are encrypted at rest and sanitised on
    /// write, but arrive as PLAIN TEXT — unlike journal `notes`, which is
    /// rich-text HTML. Nothing here should run through `RichText`, and a
    /// literal `<` must survive untouched.
    func testDescriptionIsPlainTextNotHTML() throws {
        let json = #"""
        {"id":"w1","tenantId":"t1","type":"TASK","title":"t","severity":"LOW",
         "priority":"P3","status":"OPEN","createdByUserId":"u1",
         "description":"температура < 5, без пръскане"}
        """#
        XCTAssertEqual(try decode(json).description, "температура < 5, без пръскане")
    }

    /// One unrecognised enum must not cost the item.
    func testAnUnknownEnumStillYieldsAUsableItem() throws {
        let json = #"""
        {"id":"w1","tenantId":"t1","type":"SOMETHING_NEW","title":"t",
         "severity":"LOW","priority":"P3","status":"OPEN","createdByUserId":"u1"}
        """#
        let item = try decode(json)
        XCTAssertEqual(item.type, .unknown)
        XCTAssertEqual(item.title, "t")
    }

    func testOverdueNeedsADueDateInThePastAndNoCompletion() throws {
        let past = "2020-01-01T00:00:00Z"
        let base = #"{"id":"w1","tenantId":"t1","type":"TASK","title":"t","severity":"LOW","priority":"P3","status":"OPEN","createdByUserId":"u1""#
        XCTAssertTrue(try decode(base + #","dueAt":"\#(past)"}"#).isOverdue)
        // Completed work is not overdue, however late it was.
        XCTAssertFalse(
            try decode(base + #","dueAt":"\#(past)","completedAt":"\#(past)"}"#).isOverdue
        )
        // No due date is not the same as "due now".
        XCTAssertFalse(try decode(base + "}").isOverdue)
    }

    /// The whole envelope, as the list route sends it.
    func testAListOfItemsDecodesThroughPagedResponse() throws {
        let json = #"{"rows":[\#(minimal)],"truncated":false}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let page = try d.decode(PagedResponse<WorkItem>.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.collectionKey, "rows")
    }
}
