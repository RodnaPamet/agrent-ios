import XCTest
@testable import Agrent

/// A mechanisator's one screen (#465): the queue it lists, the farm's
/// parcels on its map, the numbers on them, and that the root picks it for
/// an operator alone.
final class MechanisatorHomeTests: XCTestCase {

    private nonisolated static func parcel(_ id: String, _ name: String) -> Parcel {
        Parcel(id: id, name: name, cropType: nil, areaHa: 1.5, geometry: nil, soilType: nil,
               cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil)
    }

    /// The synthetic block from `locations-list.json`, and a second one made
    /// from it with another id and name.
    private nonisolated static func blocks() async throws -> [Location] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "locations-list", withExtension: "json"))
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var second = try XCTUnwrap(rows.first)
        second["id"] = "loc_synthetic_2"
        second["name"] = "Втори блок"
        rows.append(second)
        return try await LocationsAPI.decodeList(from: JSONSerialization.data(withJSONObject: rows))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    // MARK: - The queue

    /// No query: the route's default is "assigned to me", so no person's id
    /// goes in a URL.
    func testTheQueueIsAskedWithNoQuery() {
        XCTAssertTrue(FarmTasksAPI.queuePath.hasSuffix("/farm-tasks"), FarmTasksAPI.queuePath)
        XCTAssertTrue(FarmTasksAPI.queuePath.hasPrefix(FarmPath.root))
        XCTAssertFalse(FarmTasksAPI.queuePath.contains("?"))
    }

    /// The screen lists the current work, in the server's order; the closed
    /// row in the fixture is left out.
    @MainActor
    func testTheListIsTheCurrentQueue() async throws {
        let rows = try await FarmTasksAPI.decodeQueue(from: try fixture("farm-tasks-mine"))
        XCTAssertEqual(rows.count, 3, "positive control: the closed row decoded too")
        let store = MyTasksStore(load: { publish in publish(.loaded(rows, .fresh)) })
        await store.load()
        XCTAssertEqual(store.current?.map(\.id), ["tsk_fixture_fieldop", "tsk_fixture_2"])
    }

    // MARK: - The farm's parcels

    /// Every block's parcels, and a block that fails leaves the others on
    /// the map: the store is settled once each has answered.
    @MainActor
    func testEveryBlocksParcelsAndAFailedBlockLeavesTheRest() async throws {
        let both = try await Self.blocks()
        let store = FarmParcelsStore(
            loadBlocks: { publish in publish(.loaded(both, .fresh)) },
            loadParcels: { id, publish in
                if id == "loc_synthetic_2" {
                    publish(.failed("Няма интернет връзка."))
                } else {
                    publish(.loaded(ParcelsResponse(locationId: id, bounds: nil,
                                                    parcels: [Self.parcel("p2", "Нива 10"), Self.parcel("p1", "Нива 2")]),
                                    .fresh))
                }
            })
        XCTAssertFalse(store.settled)
        await store.load()
        XCTAssertTrue(store.settled)
        XCTAssertEqual(store.all.map(\.parcel.id), ["p1", "p2"], "by name within the block")
        XCTAssertEqual(Set(store.all.map(\.locationID)), ["loc_synthetic_1"])
        XCTAssertEqual(store.failed, ["loc_synthetic_2"])
    }

    // MARK: - The numbers

    /// One per task on each parcel it touches; a task naming a parcel twice
    /// counts once.
    func testTheCountsAreTasksPerParcel() {
        let counts = TaskParcelCounts.counts(["t1": ["a", "b", "a"], "t2": ["a"], "t3": []])
        XCTAssertEqual(counts, ["a": 2, "b": 1])
    }

    /// A task no longer current is forgotten on the next read, so a closed
    /// task stops counting.
    @MainActor
    func testATaskNoLongerCurrentStopsCounting() async {
        let counts = TaskParcelCounts(load: { id, publish in
            publish(.loaded([Self.parcel("p-\(id)", "Нива")], .fresh))
        })
        await counts.load(["t1", "t2"])
        XCTAssertEqual(counts.counts, ["p-t1": 1, "p-t2": 1])
        await counts.load(["t2"])
        XCTAssertEqual(counts.counts, ["p-t2": 1])
    }

    /// A queue row's own `parcelIds` (agri-saas #2476) are taken as given,
    /// with no read; only a row without them is read.
    @MainActor
    func testARowsOwnParcelsNeedNoRead() async throws {
        let rows = try await FarmTasksAPI.decodeQueue(from: try fixture("farm-tasks-mine"))
        XCTAssertEqual(rows.first { $0.id == "tsk_fixture_2" }?.parcelIds, ["par_holes", "par_simple", "par_nogeom"])
        @MainActor final class Reads { var ids: [String] = [] }
        let reads = Reads()
        let counts = TaskParcelCounts(load: { id, publish in
            reads.ids.append(id)
            publish(.loaded([Self.parcel("par_read", "Нива")], .fresh))
        })
        await counts.load(rows.filter { !$0.status.isArchived })
        XCTAssertEqual(reads.ids, [], "the rows carried their parcels")
        XCTAssertEqual(counts.counts, ["par_holes": 2, "par_simple": 1, "par_nogeom": 1])

        await counts.load(["t1", "t2"], known: ["t1": ["a"]])
        XCTAssertEqual(reads.ids, ["t2"], "positive control: a row without parcels is read")
        XCTAssertEqual(counts.counts, ["a": 1, "par_read": 1])
    }

    /// An odd `parcelIds` costs the field, not the row.
    func testAnOddParcelIdsCostsOnlyTheField() async throws {
        let body = #"[{"id":"t","key":null,"title":"Т","type":"FARM_TASK","status":"OPEN","parcelIds":"par_x"}]"#
        let rows = try await FarmTasksAPI.decodeQueue(from: Data(body.utf8))
        XCTAssertNil(rows.first?.parcelIds)
        XCTAssertEqual(rows.first?.title, "Т", "positive control: the rest of the row read")
    }

    /// A task whose parcels cannot be read counts nowhere, rather than
    /// somewhere wrong.
    @MainActor
    func testAnUnreadableTaskCountsNowhere() async {
        let counts = TaskParcelCounts(load: { id, publish in
            publish(id == "bad" ? .failed("Грешка.") : .loaded([Self.parcel("p", "Нива")], .fresh))
        })
        await counts.load(["bad", "good"])
        XCTAssertEqual(counts.counts, ["p": 1])
    }

    // MARK: - The parcels list

    /// The parcels with the person's tasks first, most first, then the rest
    /// by name.
    func testTheParcelsWithTasksComeFirst() {
        let places = ["Нива 10", "Ливада", "Нива 2", "Бахча"].enumerated().map { index, name in
            ParcelInBlock(locationID: "loc", parcel: Self.parcel("p\(index)", name))
        }
        let ordered = MechanisatorParcels.ordered(places, counts: ["p0": 1, "p2": 3])
        XCTAssertEqual(ordered.map(\.parcel.name), ["Нива 2", "Нива 10", "Бахча", "Ливада"])
    }

    // MARK: - The root

    /// The root draws this screen for an operator and the tabs for everyone
    /// else, and keeps one stack for it in the router.
    func testTheRootPicksTheScreenForAnOperator() throws {
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/AgrentApp.swift"), encoding: .utf8)
        let branch = try XCTUnwrap(app.range(of: "if tabs.isOperator {"))
        let screen = try XCTUnwrap(app.range(of: "MechanisatorHomeView()", range: branch.upperBound..<app.endIndex))
        let tabs = try XCTUnwrap(app.range(of: "tabView", range: screen.upperBound..<app.endIndex))
        XCTAssertLessThan(app.distance(from: branch.upperBound, to: tabs.lowerBound), 600)
        XCTAssertTrue(app.contains("router.adoptBar(isOperator ? [MechanisatorHomeView.surface] : tabs.bottomTabs)"))
        XCTAssertTrue(app.contains("TabView(selection: $router.tab)"), "positive control: the tabs are still there")
    }
}
