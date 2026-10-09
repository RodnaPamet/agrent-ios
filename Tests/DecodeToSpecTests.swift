import XCTest
@testable import Agrent

/// Where the app was stricter than the spec, or read the wrong shape
/// (agrent-ios#182) — each held against the server's own documented shape,
/// built from the fixtures the screens already use.
final class DecodeToSpecTests: XCTestCase {

    private func fixture(_ name: String) throws -> Any {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - ДНЕВНИК

    /// `LogEntry.title` and `occurredAt` are `string | null` in the spec, and
    /// `status` a free string. One such row used to fail the WHOLE list.
    func testOneEntryWithoutTitleOrDateCostsNothingElse() async throws {
        var page = try XCTUnwrap(try fixture("journal-list") as? [String: Any])
        var rows = try XCTUnwrap(page["rows"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 2, "positive control: a list to lose")
        rows[0]["title"] = NSNull()
        rows[0]["occurredAt"] = NSNull()
        rows[0]["status"] = "CANCELLED"
        page["rows"] = rows

        let slice = try await JournalAPI.decodeList(from: data(page))
        XCTAssertEqual(slice.entries.count, rows.count, "one row cost the register")
        let odd = try XCTUnwrap(slice.entries.first)
        XCTAssertNil(odd.title)
        XCTAssertNil(odd.occurredAt)
        XCTAssertEqual(odd.status, .unknown)
        XCTAssertEqual(odd.displayTitle, LogEntry.untitled)
        XCTAssertEqual(odd.status.label, "Друг статус")
        XCTAssertNotNil(slice.entries[1].occurredAt, "positive control: a dated row still has its date")
    }

    func testAnUnknownStatusIsNeverOfferedForWriting() {
        XCTAssertEqual(CreateLogEntry(type: .activity, title: "x").status, .done)
    }

    // MARK: - A task's detail

    /// `severity`, `priority` and `createdByUserId` are nullable in the spec.
    /// The app no longer reads `priority` (#236), and a null one must still
    /// cost nothing.
    func testATaskWithNullSeverityPriorityAndCreatorOpens() async throws {
        var task = try XCTUnwrap(try fixture("task-detail-fieldop") as? [String: Any])
        XCTAssertEqual(task["severity"] as? String, "MEDIUM", "positive control: the fields were there")
        task["severity"] = NSNull()
        task["priority"] = NSNull()
        task["createdByUserId"] = NSNull()

        let item = try await WorkItemAPI.decodeDetail(from: data(task))
        XCTAssertEqual(item.severity, .unknown)
        XCTAssertNil(item.createdByUserId)
    }

    /// A null is `unknownCase` for every lenient enum, as an unknown value is
    /// — and an OPTIONAL one still decodes a null as nil.
    func testALenientEnumReadsNullAsUnknown() throws {
        struct Row: Decodable { let required: WorkItemSeverity; let optional: WorkItemSeverity? }
        let row = try JSONDecoder().decode(Row.self, from: Data(#"{"required":null,"optional":null}"#.utf8))
        XCTAssertEqual(row.required, .unknown)
        XCTAssertNil(row.optional)
    }

    // MARK: - Insurance

    /// `quote.engineVersion` is a required INTEGER in the spec.
    func testALeadsQuoteDecodesItsIntegerEngineVersion() throws {
        let lead = try JSONDecoder().decode(CreatedLead.self, from: Data("""
        {"id":"lead_1","status":"NEW","quote":{"premiumCents":12345,"instalmentsCents":[12345],
         "tariffBp":1000,"engineVersion":2}}
        """.utf8))
        XCTAssertEqual(lead.quote?.engineVersion, 2)
    }

    // MARK: - Products

    private func item(_ extra: String) throws -> InputItem {
        try JSONDecoder().decode(InputItem.self, from: Data("""
        {"id":"itm_1","name":"Синтетичен продукт","category":"PESTICIDE","defaultUnit":null\(extra)}
        """.utf8))
    }

    /// The server's `isArchetype` wins; the old inference only stands in for
    /// a server that does not send it.
    func testTheServersArchetypeFlagWins() throws {
        XCTAssertTrue(try item(#","createdByUserId":"usr_1","isArchetype":true"#).isArchetype)
        XCTAssertFalse(try item(#","createdByUserId":null,"isArchetype":false"#).isArchetype)
        XCTAssertTrue(try item(#","createdByUserId":null"#).isArchetype, "legacy: no flag, no creator")
        XCTAssertFalse(try item(#","createdByUserId":"usr_1""#).isArchetype, "legacy: a creator")
    }
}

/// A new product comes back WHOLE, and never as a sample (agrent-ios#182).
/// NOTHING HERE CREATES ONE: the store's create and re-read are injected.
@MainActor
final class NewProductSaveTests: XCTestCase {

    private let draft = CreateItem(name: "Синтетичен продукт", category: "PESTICIDE", defaultUnitId: "unt_l",
                                   activeIngredient: nil, pppRegistrationNo: nil, quarantinePeriodDays: nil)
    private let ack = CreatedItem(id: "itm_new", name: "Синтетичен продукт", category: "PESTICIDE")

    private func row(_ id: String, archetype: Bool) -> InputItem {
        InputItem(id: id, name: "x", category: "PESTICIDE", defaultUnit: nil,
                  createdByUserId: archetype ? nil : "usr_1", serverIsArchetype: archetype)
    }

    func testTheRowIsReadBackAfterTheCreate() async {
        let full = row("itm_new", archetype: false)
        let store = NewProductStore(create: { [ack] _ in ack },
                                    reread: { [full] in [self.row("itm_other", archetype: true), full] })
        let saved = await store.save(draft, unit: nil)
        XCTAssertEqual(saved, full)
    }

    /// The read back failed: the row as the farmer entered it — theirs, so
    /// never a sample.
    func testWithNoReadBackTheProductIsTheFarmersOwn() async {
        let unit = try? JSONDecoder().decode(Unit.self, from: Data(#"{"id":"unt_l","key":"L","symbol":"л"}"#.utf8))
        let store = NewProductStore(create: { [ack] _ in ack }, reread: { nil })
        let saved = await store.save(draft, unit: unit)
        XCTAssertEqual(saved?.id, "itm_new")
        XCTAssertEqual(saved?.isArchetype, false, "the farmer's own product read as a sample")
        XCTAssertEqual(saved?.defaultUnit?.id, "unt_l", "the unit just chosen was lost")
    }

    /// A duplicate name is a 409 — said as one, not as a stale edit.
    func testADuplicateNameSaysSo() async {
        let store = NewProductStore(
            create: { _ in throw APIClient.APIError.conflict(currentVersion: nil, expectedVersion: nil) },
            reread: { nil })
        let saved = await store.save(draft, unit: nil)
        XCTAssertNil(saved)
        XCTAssertEqual(store.failure, NewProductStore.duplicateName)
    }
}
