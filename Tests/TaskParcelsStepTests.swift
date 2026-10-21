import XCTest
@testable import Agrent

/// «Нова задача»'s parcels step (#388): the link each parcel sends, a
/// conflict counted as linked, the save that never creates the task twice,
/// and a block's parcels as the step lists them. Synthetic ids and names.
final class TaskParcelsStepTests: XCTestCase {

    // MARK: - The link

    func testALinkIsAParcelRelatedToTheTask() throws {
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TaskLinksAPI.Body(entityId: "par_synthetic_1"))) as? [String: Any])
        XCTAssertEqual(sent as NSDictionary,
                       ["entityType": "PARCEL", "entityId": "par_synthetic_1", "relation": "RELATES_TO"] as NSDictionary)
    }

    /// A second link of the same parcel answers 409, in either shape
    /// `APIClient` gives it. It is linked either way. Nothing else counts.
    func testAConflictMeansAlreadyLinked() {
        XCTAssertTrue(TaskLinksAPI.isAlreadyLinked(.http(status: 409, code: "CONFLICT", message: nil)))
        XCTAssertTrue(TaskLinksAPI.isAlreadyLinked(.conflict(currentVersion: nil, expectedVersion: nil)))
        XCTAssertFalse(TaskLinksAPI.isAlreadyLinked(.http(status: 400, code: "VALIDATION_ERROR", message: nil)))
        XCTAssertFalse(TaskLinksAPI.isAlreadyLinked(.http(status: 404, code: "TASK_NOT_FOUND", message: nil)))
        XCTAssertFalse(TaskLinksAPI.isAlreadyLinked(.notSignedIn))
    }

    // MARK: - The save

    /// Each parcel is its own request. One that fails is left for a retry,
    /// and the rest still land.
    func testLinksThatFailAreLeftForARetry() async {
        actor Sent { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }
        let sent = Sent()
        let linked = await NewTaskSave.link(["par_a", "par_b", "par_c"], to: "tsk_new") { parcel, task in
            XCTAssertEqual(task, "tsk_new")
            await sent.add(parcel)
            if parcel == "par_b" { throw URLError(.notConnectedToInternet) }
        }
        XCTAssertEqual(linked, ["par_a", "par_c"])
        let order = await sent.ids
        XCTAssertEqual(order, ["par_a", "par_b", "par_c"], "one at a time, in order")
    }

    /// A retry sends only what isn't linked yet, so «Опитай пак» after a
    /// partial save is never a second task and never a second link.
    func testARetrySendsOnlyWhatIsLeft() {
        XCTAssertEqual(NewTaskSave.pending(chosen: ["par_c", "par_a", "par_b"], linked: []),
                       ["par_a", "par_b", "par_c"])
        XCTAssertEqual(NewTaskSave.pending(chosen: ["par_a", "par_b", "par_c"], linked: ["par_a", "par_c"]),
                       ["par_b"])
        XCTAssertEqual(NewTaskSave.pending(chosen: [], linked: []), [], "no parcels is a task without them")
    }

    func testThePartialSaveIsSaidInBulgarian() {
        XCTAssertEqual(NewTaskSave.partial(1),
                       "Задачата е създадена, но 1 парцел не беше добавен. Опитайте пак или завършете без тях.")
        XCTAssertEqual(NewTaskSave.partial(3),
                       "Задачата е създадена, но 3 парцела не бяха добавени. Опитайте пак или завършете без тях.")
    }

    // MARK: - A block's parcels

    private func parcel(_ id: String, _ name: String) -> Parcel {
        Parcel(id: id, name: name, cropType: nil, areaHa: 1.5, geometry: nil, soilType: nil,
               cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil)
    }

    /// The synthetic block from `locations-list.json` («Synthetic Land»).
    private func block() async throws -> Location {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "locations-list", withExtension: "json"))
        let blocks = try await LocationsAPI.decodeList(from: Data(contentsOf: url))
        return try XCTUnwrap(blocks.first)
    }

    /// By name, as a farmer reads a list, with numbers in their order, and
    /// every field carries its block.
    func testABlocksParcelsAreListedByName() async throws {
        let fields = TaskBlocksStore.fields(
            [parcel("p3", "Нива 10"), parcel("p1", "Нива 2"), parcel("p2", "Ливада")],
            in: try await block())
        XCTAssertEqual(fields.map(\.parcel.name), ["Ливада", "Нива 2", "Нива 10"])
        XCTAssertEqual(Set(fields.map(\.blockID)), ["loc_synthetic_1"])
        XCTAssertEqual(Set(fields.map(\.blockName)), ["Synthetic Land"])
    }

    /// A block's parcels as the store publishes them, through injected reads.
    @MainActor
    func testTheStoreLoadsABlocksParcels() async throws {
        let one = try await block()
        let store = TaskBlocksStore(
            loadBlocks: { publish in publish(.loaded([one], .fresh)) },
            loadParcels: { id, publish in
                XCTAssertEqual(id, "loc_synthetic_1")
                publish(.loaded(ParcelsResponse(locationId: id, bounds: nil,
                                                parcels: [self.parcel("p1", "Нива 2")]), .fresh))
            })
        await store.load()
        XCTAssertEqual(store.blocks.value?.map(\.id), ["loc_synthetic_1"])
        await store.loadFields(for: one)
        XCTAssertEqual(store.fields["loc_synthetic_1"]?.value?.map(\.id), ["p1"])
    }

    /// A read that fails after the block was shown keeps what it showed.
    @MainActor
    func testAFailedReadKeepsAShownBlock() async throws {
        let one = try await block()
        var fail = false
        let store = TaskBlocksStore(
            loadBlocks: { publish in publish(.loaded([one], .fresh)) },
            loadParcels: { id, publish in
                publish(fail ? .failed("Няма интернет връзка.")
                             : .loaded(ParcelsResponse(locationId: id, bounds: nil,
                                                       parcels: [self.parcel("p1", "Нива 2")]), .fresh))
            })
        await store.loadFields(for: one)
        fail = true
        await store.loadFields(for: one)
        XCTAssertEqual(store.fields["loc_synthetic_1"]?.value?.map(\.id), ["p1"])
    }
}
