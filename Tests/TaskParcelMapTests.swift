import MapKit
import XCTest
@testable import Agrent

/// The task map (agrent-ios#177): which of a task's parcels are drawn, how
/// each is marked, what the camera frames and what is said aloud. All of it is
/// decided in `TaskParcelMapContent`, away from MapKit, which is not hosted
/// here — the view draws what the value says.

// MARK: - Fixtures

/// A synthetic square parcel near 42.5°N 25.1°E, `offset` degrees north-east,
/// or one with no geometry.
private func parcel(_ id: String, name: String? = nil, offset: Double = 0, drawable: Bool = true) throws -> Parcel {
    let lon = 25.1 + offset, lat = 42.5 + offset
    let ring = [[lon, lat], [lon + 0.01, lat], [lon + 0.01, lat + 0.01], [lon, lat + 0.01], [lon, lat]]
    let points = ring.map { "[\($0[0]),\($0[1])]" }.joined(separator: ",")
    let geometry = drawable ? #"{"type":"MultiPolygon","coordinates":[[["# + points + "]]]}" : "null"
    return try JSONDecoder().decode(Parcel.self, from: Data("""
    {"id":"\(id)","name":"\(name ?? id)","cropType":null,"areaHa":1,"geometry":\(geometry)}
    """.utf8))
}

private func line(_ id: String, parcel: String, _ status: OperationLineStatus) -> OperationLine {
    OperationLine(
        id: id, status: status, version: 3, doseValue: WireDecimal(Decimal(string: "0.25")!),
        product: .init(id: "itm_1", name: "Примерен хербицид"),
        doseUnit: .init(id: "unt_1", symbol: "л/дка", name: "литра на декар"),
        parcel: .init(id: parcel, name: parcel, areaHa: nil),
        completedAt: nil)
}

private func row(_ id: String, parcel: String, _ status: OperationLineStatus) -> LineState {
    LineState(line: line(id, parcel: parcel, status), waiting: nil, conflict: nil, refused: [])
}

private func queued(_ lineID: String, _ status: OperationLineStatus) -> PendingOperation {
    .mark(PendingOperation.LineMark(taskID: "tsk_1", lineID: lineID, status: status.rawValue, seenVersion: 3),
          ownerUserID: "usr_me", summary: "x", payload: Data(), reason: nil,
          at: Date(timeIntervalSince1970: 1_900_000_000))
}

// MARK: - Marks

final class TaskParcelMapContentTests: XCTestCase {

    /// Each of the job's parcels takes its line's state; the location's other
    /// parcel is context, not marked.
    func testEachParcelIsMarkedByItsLine() throws {
        let parcels = try ["a", "b", "c", "d"].enumerated().map { try parcel($1, offset: Double($0) * 0.02) }
        let map = try XCTUnwrap(TaskParcelMapContent.fieldOperation(parcels: parcels, rows: [
            row("l1", parcel: "a", .pending),
            row("l2", parcel: "b", .done),
            row("l3", parcel: "c", .skipped),
        ]))
        XCTAssertEqual(map.marked.map(\.id), ["a", "b", "c"], "the job's order, not the location's")
        XCTAssertEqual(map.marked.map(\.mark), [.pending, .done, .skipped])
        XCTAssertEqual(map.context.map(\.id), ["d"])
        XCTAssertEqual(map.undrawable, 0)
    }

    /// A mark still on the phone colours its parcel as it changes its line —
    /// the map and the list under it read the same `shown`.
    func testAQueuedMarkShowsOnTheMapAsInTheList() throws {
        let rows = FieldOperationRules.rows(
            lines: [line("l1", parcel: "a", .pending)], pending: [queued("l1", .done)], taskID: "tsk_1")
        XCTAssertEqual(rows.map(\.shown), [.done], "positive control: the list shows the queued mark")
        let map = try XCTUnwrap(TaskParcelMapContent.fieldOperation(parcels: [try parcel("a")], rows: rows))
        XCTAssertEqual(map.marked.map(\.mark), [.done])
    }

    /// One line per product, so one parcel can have several. Still to do while
    /// any line is; done if any was done; skipped only when all were skipped.
    func testAParcelWithSeveralLinesIsToDoWhileAnyLineIs() {
        XCTAssertEqual(TaskParcelMark(lines: [.done, .pending]), .pending)
        XCTAssertEqual(TaskParcelMark(lines: [.unknown, .done]), .pending, "an unknown state is not finished")
        XCTAssertEqual(TaskParcelMark(lines: [.skipped, .done]), .done)
        XCTAssertEqual(TaskParcelMark(lines: [.skipped, .skipped]), .skipped)
    }

    func testTwoLinesOnOneParcelDrawItOnce() throws {
        let map = try XCTUnwrap(TaskParcelMapContent.fieldOperation(parcels: [try parcel("a")], rows: [
            row("l1", parcel: "a", .done),
            row("l2", parcel: "a", .pending),
        ]))
        XCTAssertEqual(map.marked.map(\.id), ["a"])
        XCTAssertEqual(map.marked.map(\.mark), [.pending])
    }

    // MARK: - What can be drawn

    /// No outline, or not in the location's parcels at all: counted and said,
    /// never drawn and never dropped silently.
    func testParcelsWithNoOutlineAreCountedNotDrawn() throws {
        let map = try XCTUnwrap(TaskParcelMapContent.fieldOperation(
            parcels: [try parcel("a"), try parcel("b", drawable: false)],
            rows: [row("l1", parcel: "a", .pending), row("l2", parcel: "b", .done), row("l3", parcel: "gone", .done)]))
        XCTAssertEqual(map.marked.map(\.id), ["a"])
        XCTAssertEqual(map.undrawable, 2)
        XCTAssertFalse(map.context.contains { $0.id == "b" }, "an undrawable parcel came back as context")
    }

    /// Nothing of the task's to draw is no map — not a map of the location's
    /// other fields, which would show the task as being about them.
    func testNoDrawableTaskParcelIsNoMap() throws {
        XCTAssertNil(TaskParcelMapContent.fieldOperation(
            parcels: [try parcel("a", drawable: false), try parcel("other")],
            rows: [row("l1", parcel: "a", .pending)]))
        XCTAssertNil(TaskParcelMapContent.fieldOperation(parcels: [try parcel("other")], rows: []))
    }

    /// The camera frames the task's parcels, not the whole location: a far
    /// field in the same location must not pull the view out to include it.
    func testTheCameraFramesTheTasksParcels() throws {
        let map = try XCTUnwrap(TaskParcelMapContent(
            parcels: [try parcel("near"), try parcel("far", offset: 1)],
            marks: [(parcelID: "near", mark: .linked)]))
        XCTAssertEqual(map.region.center.latitude, 42.505, accuracy: 0.001)
        XCTAssertEqual(map.region.center.longitude, 25.105, accuracy: 0.001)
        XCTAssertLessThan(map.region.span.latitudeDelta, 0.1, "framed the location, not the task")
        // Positive control: framing both WOULD have reached the far field.
        let both = try XCTUnwrap(MKCoordinateRegion(fitting: [try parcel("near"), try parcel("far", offset: 1)]))
        XCTAssertGreaterThan(both.span.latitudeDelta, 1)
    }

    // MARK: - Words

    func testTheLegendListsOnlyWhatIsOnTheMapInItsOrder() throws {
        let map = try XCTUnwrap(TaskParcelMapContent(
            parcels: [try parcel("a"), try parcel("b", offset: 0.02)],
            marks: [(parcelID: "a", mark: .skipped), (parcelID: "b", mark: .pending)]))
        XCTAssertEqual(map.legend, [.pending, .skipped])
        XCTAssertEqual(TaskParcelMark.pending.label, "Чакащо", "the lines' own word")
    }

    /// One sentence per state, by name, and the parcels it could not draw.
    func testTheSummaryNamesEachParcelByItsState() throws {
        let map = try XCTUnwrap(TaskParcelMapContent(
            parcels: [try parcel("a", name: "Нива 1"), try parcel("b", name: "Нива 2", offset: 0.02),
                      try parcel("c", name: "Нива 3", offset: 0.04)],
            marks: [(parcelID: "a", mark: .pending), (parcelID: "b", mark: .done),
                    (parcelID: "c", mark: .pending), (parcelID: "x", mark: .done)]))
        XCTAssertEqual(map.spokenSummary,
                       "Карта на парцелите. Чакащо: Нива 1, Нива 3. Готово: Нива 2. "
                       + "1 парцел няма очертания и не е на картата.")
    }

    func testTheUndrawableNote() {
        XCTAssertNil(TaskParcelMapContent.undrawableNote(0))
        XCTAssertEqual(TaskParcelMapContent.undrawableNote(1), "1 парцел няма очертания и не е на картата.")
        XCTAssertEqual(TaskParcelMapContent.undrawableNote(3), "3 парцела нямат очертания и не са на картата.")
        for text in [TaskParcelMapContent.undrawableNote(1), TaskParcelMapContent.undrawableNote(2)] {
            XCTAssertNil(text?.range(of: "[A-Za-z]", options: .regularExpression), "Latin in UI text: \(text ?? "")")
        }
    }
}

// MARK: - Decoding the job's map

final class FieldOperationMapDecodingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func detail(location: String, parcels: String) -> Data {
        Data("""
        {"task":{"id":"tsk_1","key":"FT-1","assigneeUserId":null,"status":"IN_PROGRESS"},
         "lines":[{"id":"opl_1","status":"PENDING","version":3,"doseValue":"0.25",
                   "product":{"id":"itm_1","name":"Примерен хербицид"},
                   "doseUnit":{"id":"unt_1","symbol":"л/дка","name":null},
                   "parcel":{"id":"par_1","name":"SYNTH-1","areaHa":"2"},"completedAt":null}],
         "location":\(location),
         "parcels":\(parcels),
         "progress":{"total":1,"done":0}}
        """.utf8)
    }

    /// The fixture job, through the app's own decode: its location, the
    /// location's three parcels, and a map of the two that have outlines.
    func testTheFixtureJobCarriesItsLocationAndParcels() async throws {
        let job = try await FieldOperationAPI.decodeDetail(from: try fixture("field-operation-detail"))
        XCTAssertEqual(job.location, FieldOperationDetail.Place(id: "loc_synthetic_1", name: "Synthetic Land"))
        XCTAssertEqual(job.parcels.map(\.id), ["par_holes", "par_simple", "par_nogeom"])

        let rows = job.lines.map { LineState(line: $0, waiting: nil, conflict: nil, refused: []) }
        let map = try XCTUnwrap(TaskParcelMapContent.fieldOperation(parcels: job.parcels, rows: rows))
        XCTAssertEqual(map.marked.map(\.id), ["par_holes", "par_simple"])
        XCTAssertEqual(map.marked.map(\.mark), [.pending, .done])
        XCTAssertEqual(map.undrawable, 1, "SYNTH-3 has no outline")
    }

    /// One bad parcel costs that parcel, and the lines are untouched.
    func testABrokenParcelCostsOnlyItself() async throws {
        let job = try await FieldOperationAPI.decodeDetail(from: detail(
            location: #"{"id":"loc_1","name":"Синтетична земя","boundsJson":null}"#,
            parcels: #"[{"id":"par_1","name":"SYNTH-1","geometry":null},{"id":7}]"#))
        XCTAssertEqual(job.parcels.map(\.id), ["par_1"])
        XCTAssertEqual(job.lines.map(\.id), ["opl_1"])
    }

    /// The map is context and the lines are the work: a `parcels` or
    /// `location` that will not decode at all costs the map, never the job.
    func testABrokenMapPayloadCostsTheMapNotTheLines() async throws {
        let job = try await FieldOperationAPI.decodeDetail(from: detail(location: "7", parcels: #""nope""#))
        XCTAssertNil(job.location)
        XCTAssertTrue(job.parcels.isEmpty)
        XCTAssertEqual(job.lines.map(\.id), ["opl_1"])
    }

    /// The spec's NULL location: «a signal, not just an absence».
    func testANullLocationIsNoLocation() async throws {
        let job = try await FieldOperationAPI.decodeDetail(from: detail(location: "null", parcels: "[]"))
        XCTAssertNil(job.location)
        XCTAssertTrue(job.parcels.isEmpty)
    }

    /// A landed mark rewrites one line and keeps the map it was drawn on.
    func testApplyingAMarkKeepsTheMap() async throws {
        let job = try await FieldOperationAPI.decodeDetail(from: try fixture("field-operation-detail"))
        let line = try XCTUnwrap(job.lines.first)
        let next = job.applying(.done, version: (line.version ?? 0) + 1, toLine: line.id)
        XCTAssertEqual(next.lines.first?.status, .done, "positive control: the mark was applied")
        XCTAssertEqual(next.location, job.location)
        XCTAssertEqual(next.parcels, job.parcels)
    }
}
