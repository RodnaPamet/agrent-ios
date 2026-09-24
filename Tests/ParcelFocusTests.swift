import XCTest
@testable import Agrent

final class ParcelFocusTests: XCTestCase {

    private func parcel(_ id: String) throws -> Parcel {
        try JSONDecoder().decode(Parcel.self, from: Data("""
        {"id":"\(id)","name":"\(id)","cropType":null,"areaHa":1,"geometry":null,
         "soilType":null,"cadastralId":null,"ekatte":null,"hasActiveLease":false}
        """.utf8))
    }

    private func parcels(_ ids: [String]) throws -> [Parcel] {
        try ids.map(parcel)
    }

    func testWalksTheListInOrder() throws {
        let list = try parcels(["a", "b", "c"])
        XCTAssertEqual(ParcelFocus.next(after: "a", in: list)?.id, "b")
        XCTAssertEqual(ParcelFocus.next(after: "b", in: list)?.id, "c")
    }

    /// Wraps, like the web's plain modulo. No end stop.
    func testWrapsAtTheEnd() throws {
        let list = try parcels(["a", "b", "c"])
        XCTAssertEqual(ParcelFocus.next(after: "c", in: list)?.id, "a")
    }

    func testNoFocusYetStartsAtTheFirst() throws {
        let list = try parcels(["a", "b"])
        XCTAssertEqual(ParcelFocus.next(after: nil, in: list)?.id, "a")
    }

    /// The parcel we were on has been deleted from the farm between loads.
    /// The button restarts rather than going dead.
    func testAnUnknownIDRestartsRatherThanFailing() throws {
        let list = try parcels(["a", "b"])
        XCTAssertEqual(ParcelFocus.next(after: "gone", in: list)?.id, "a")
    }

    /// Recentring is a real thing to want. It must not refuse.
    func testOneParcelAlwaysReturnsThatParcel() throws {
        let list = try parcels(["only"])
        XCTAssertEqual(ParcelFocus.next(after: nil, in: list)?.id, "only")
        XCTAssertEqual(ParcelFocus.next(after: "only", in: list)?.id, "only")
    }

    func testNoParcelsReturnsNil() throws {
        XCTAssertNil(ParcelFocus.next(after: nil, in: []))
        XCTAssertNil(ParcelFocus.next(after: "a", in: []))
    }

    /// THE REGRESSION THIS TYPE EXISTS FOR. The list is rebuilt after every
    /// recorded operation; an index would survive that and point elsewhere.
    func testFocusSurvivesTheListBeingRebuiltWithAParcelRemoved() throws {
        let before = try parcels(["a", "b", "c"])
        XCTAssertEqual(ParcelFocus.next(after: "a", in: before)?.id, "b")

        // "a" is gone on the next load. An index of 1 would now mean "c".
        let after = try parcels(["b", "c"])
        XCTAssertEqual(ParcelFocus.next(after: "b", in: after)?.id, "c")
    }

    // MARK: - Spoken position

    func testPositionCountsOverTheParcelsBeingCycled() throws {
        let list = try parcels(["a", "b", "c"])
        XCTAssertEqual(ParcelFocus.position(of: list[1], in: list), "парцел 2 от 3")
    }

    func testPositionIsNilForAParcelNotInTheList() throws {
        XCTAssertNil(ParcelFocus.position(of: try parcel("x"), in: try parcels(["a"])))
    }
}

/// The three-way cycle. Pure, so it needs no view.
final class ParcelMapModeTests: XCTestCase {

    func testCyclesThroughAllThreeAndReturns() {
        XCTAssertEqual(ParcelMapMode.precise.next, .simplified)
        XCTAssertEqual(ParcelMapMode.simplified.next, .schematic)
        XCTAssertEqual(ParcelMapMode.schematic.next, .precise)
    }

    /// Three presses from anywhere come home. If `allCases` ever grows a
    /// case without the button being reconsidered, this still passes — but
    /// the count assertion below fails, which is the point.
    func testThreePressesReturnToTheStart() {
        for mode in ParcelMapMode.allCases {
            XCTAssertEqual(mode.next.next.next, mode)
        }
        XCTAssertEqual(ParcelMapMode.allCases.count, 3,
                       "a fourth mode needs the button reconsidered, not just this test updated")
    }

    /// The sown/fallow key belongs on exactly the modes that draw it.
    func testOnlyTheCropColouredModesShowTheLegend() {
        XCTAssertFalse(ParcelMapMode.precise.showsSownFallow)
        XCTAssertTrue(ParcelMapMode.simplified.showsSownFallow)
        XCTAssertTrue(ParcelMapMode.schematic.showsSownFallow)
    }

    /// The schematic is a Canvas: no camera to command, no target to press.
    func testOnlyTheSchematicIsNotSatellite() {
        XCTAssertTrue(ParcelMapMode.precise.isSatellite)
        XCTAssertTrue(ParcelMapMode.simplified.isSatellite)
        XCTAssertFalse(ParcelMapMode.schematic.isSatellite)
    }

    /// Stored by raw value, so renaming a case silently changes what a
    /// phone's saved preference means.
    func testRawValuesArePinned() {
        XCTAssertEqual(ParcelMapMode.precise.rawValue, "precise")
        XCTAssertEqual(ParcelMapMode.simplified.rawValue, "simplified")
        XCTAssertEqual(ParcelMapMode.schematic.rawValue, "schematic")
    }

    /// Every mode must have a distinct label and glyph, or the button lies
    /// about where it is going.
    func testLabelsAndIconsAreDistinct() {
        XCTAssertEqual(Set(ParcelMapMode.allCases.map(\.label)).count, 3)
        XCTAssertEqual(Set(ParcelMapMode.allCases.map(\.icon)).count, 3)
        XCTAssertEqual(Set(ParcelMapMode.allCases.map(\.hint)).count, 3)
    }
}
