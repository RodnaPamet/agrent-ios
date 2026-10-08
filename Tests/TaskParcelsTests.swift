import XCTest
@testable import Agrent

/// Any task's parcels (agrent-ios#177, agri-saas #1410): the route's body,
/// and the map drawn from it.
final class TaskParcelsTests: XCTestCase {

    private let square = """
        {"type":"MultiPolygon","coordinates":[[[[25.1,42.5],[25.11,42.5],[25.11,42.51],[25.1,42.51],[25.1,42.5]]]]}
        """

    private func decode(_ items: String) async throws -> [Parcel] {
        try await WorkItemAPI.decodeParcels(from: Data(#"{"parcels":[\#(items)]}"#.utf8))
    }

    // MARK: - The body

    /// An outline and a null both decode — null is «no outline», a normal
    /// state the route says to keep, and the order is the route's.
    func testOutlinesAndNullsDecodeInTheRoutesOrder() async throws {
        let parcels = try await decode("""
            {"id":"p1","name":"A","geometry":\(square)},
            {"id":"p2","name":"B","geometry":null}
            """)
        XCTAssertEqual(parcels.map(\.id), ["p1", "p2"])
        XCTAssertTrue(parcels[0].isDrawable)
        XCTAssertNil(parcels[1].geometry)
    }

    /// An outline this build cannot read keeps its parcel, without the
    /// outline — dropping it would make the list disagree with the task.
    /// Only an item that is not a parcel at all (no name) is dropped.
    func testAnUnreadableOutlineKeepsItsParcel() async throws {
        let parcels = try await decode("""
            {"id":"p1","name":"A","geometry":{"type":"Polygon","coordinates":[[[25.1,42.5],[25.2,42.5],[25.1,42.5]]]}},
            {"id":"p2"},
            {"id":"p3","name":"C","geometry":\(square)}
            """)
        XCTAssertEqual(parcels.map(\.name), ["A", "C"])
        XCTAssertNil(parcels[0].geometry)
        XCTAssertFalse(parcels[0].isDrawable)
    }

    /// `[]` is a task without parcels, not a failure.
    func testNoParcelsIsAnEmptyList() async throws {
        let parcels = try await decode("")
        XCTAssertEqual(parcels, [])
    }

    func testThePathIsUnderTheTask() {
        XCTAssertEqual(WorkItemAPI.parcelsPath("tsk_1"), "\(WorkItemAPI.detailPath("tsk_1"))/parcels")
    }

    // MARK: - The map

    /// Every parcel marked alike, nothing around them (the route sends no
    /// location), and the one without an outline said under the map.
    func testALinkedMapMarksEveryParcelAlike() async throws {
        let parcels = try await decode("""
            {"id":"p1","name":"SYNTH-1","geometry":\(square)},
            {"id":"p2","name":"SYNTH-2","geometry":\(square)},
            {"id":"p3","name":"SYNTH-3","geometry":null}
            """)
        let map = try XCTUnwrap(TaskParcelMapContent.linked(parcels))
        XCTAssertEqual(map.marked.map(\.mark), [.linked, .linked])
        XCTAssertEqual(map.context, [])
        XCTAssertEqual(map.legend, [.linked])
        XCTAssertEqual(map.undrawable, 1)
        XCTAssertEqual(
            map.spokenSummary,
            "Карта на парцелите. Парцели на задачата: SYNTH-1, SYNTH-2. 1 парцел няма очертания и не е на картата."
        )
    }

    /// No map when nothing can be drawn: a map of nothing in particular says
    /// the task is about nowhere.
    func testNoMapWhenNoParcelHasAnOutline() async throws {
        let parcels = try await decode(#"{"id":"p1","name":"A","geometry":null}"#)
        XCTAssertNil(TaskParcelMapContent.linked(parcels))
        XCTAssertNil(TaskParcelMapContent.linked([]))
    }
}
