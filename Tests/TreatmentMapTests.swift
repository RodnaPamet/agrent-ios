import XCTest
@testable import Agrent

/// «Виж на картата» on a recorded treatment (#399): its parcels from its
/// tasks, by block, once each, and a failure is the whole answer.
/// Synthetic fixture: `field-operation-detail.json`, three lines over
/// «Synthetic Land», one parcel with no outline.
final class TreatmentMapTests: XCTestCase {

    private nonisolated static func detail() async throws -> FieldOperationDetail {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "field-operation-detail", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try await FieldOperationAPI.decodeDetail(from: data)
    }

    func testTheTasksAreReadFromTheTreatment() throws {
        let data = Data(#"{"treatmentGroupId":"trg_synthetic","complete":true,"completedCount":3,"parcelCount":3,"taskIds":["tsk_a","tsk_b"],"occurredOn":"2026-10-20"}"#.utf8)
        XCTAssertEqual(try TreatmentAPI.taskIDs(from: data), ["tsk_a", "tsk_b"])
    }

    /// Each treated parcel once, named in its block, with the block's outline
    /// where it has one, and by name.
    func testTheParcelsAreTheTreatedOnesInTheirBlock() async throws {
        let fields = TreatmentMapStore.fields(from: [try await Self.detail()])
        XCTAssertEqual(fields.map(\.parcel.name), ["SYNTH-1", "SYNTH-2", "SYNTH-3"])
        XCTAssertEqual(Set(fields.map(\.blockName)), ["Synthetic Land"])
        XCTAssertEqual(fields.filter { $0.parcel.isDrawable }.count, 2, "SYNTH-3 has no outline")
    }

    /// The same parcel on two product lines, or in two tasks, is listed once.
    func testAParcelIsListedOnce() async throws {
        let one = try await Self.detail()
        XCTAssertEqual(TreatmentMapStore.fields(from: [one, one]).count, 3)
    }

    @MainActor
    func testItLoadsEveryBlock() async throws {
        let one = try await Self.detail()
        let store = TreatmentMapStore(
            handle: "trg_synthetic",
            loadTasks: { _ in .loaded(["tsk_a"], .fresh) },
            loadDetail: { id in
                XCTAssertEqual(id, "tsk_a")
                return .loaded(one, .fresh)
            })
        await store.load()
        XCTAssertEqual(store.state.value?.count, 3)
        XCTAssertEqual(store.outlines.values.filter { !$0.isEmpty }.count, 2, "only drawable parcels have outlines")
    }

    /// One block missing would show the treatment as smaller than it was.
    @MainActor
    func testAFailedBlockIsAFailureNotAPartialMap() async throws {
        let one = try await Self.detail()
        let store = TreatmentMapStore(
            handle: "trg_synthetic",
            loadTasks: { _ in .loaded(["tsk_a", "tsk_b"], .fresh) },
            loadDetail: { id in id == "tsk_a" ? .loaded(one, .fresh) : .failed("Няма интернет връзка.") })
        await store.load()
        XCTAssertNil(store.state.value)
        XCTAssertTrue(store.state.isFailed)
    }

    /// From the saved screen: the parcels are in hand, nothing is read.
    @MainActor
    func testTheSavedScreenNeedsNoRead() async throws {
        let fields = TreatmentMapStore.fields(from: [try await Self.detail()])
        let store = TreatmentMapStore(fields: fields)
        await store.load()
        XCTAssertEqual(store.state.value?.map(\.id), fields.map(\.id))
    }

    func testTheTitleNamesWhatWasDone() {
        XCTAssertEqual(TreatmentMapView.title(for: .spray), "Третирани парцели")
        XCTAssertEqual(TreatmentMapView.title(for: .fertilize), "Наторени парцели")
        XCTAssertEqual(TreatmentMapView.title(for: nil), "Третирани парцели")
    }
}
