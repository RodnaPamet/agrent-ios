import XCTest
@testable import Agrent

/// A parcel's own name (owner, 2026-11-17, #667): a nickname the app and
/// Агрент use, beside the field number the ДНЕВНИК keeps printing.
final class ParcelNicknameTests: XCTestCase {
    private func parcel(displayName: String?) throws -> Parcel {
        var json = #"{"id":"p1","name":"20688.13","cropType":"Maize","areaHa":1.5,"geometry":null,"#
            + #""soilType":null,"cadastralId":null,"ekatte":null,"hasActiveLease":false,"absentFromImportAt":null"#
        if let displayName { json += #","displayName":"\#(displayName)""# }
        json += "}"
        return try JSONDecoder().decode(Parcel.self, from: Data(json.utf8))
    }

    func testANicknameIsWhatTheParcelIsCalledAndTheNumberStays() throws {
        let named = try parcel(displayName: "Нивата до реката")
        XCTAssertEqual(named.nickname, "Нивата до реката")
        XCTAssertEqual(named.title, "Нивата до реката")
        // The number the ДНЕВНИК prints is untouched.
        XCTAssertEqual(named.name, "20688.13")
    }

    func testAnOlderServerWithoutTheFieldStillDecodes() throws {
        let plain = try parcel(displayName: nil)
        XCTAssertNil(plain.displayName)
        XCTAssertNil(plain.nickname)
        XCTAssertEqual(plain.title, "20688.13")
    }

    func testABlankOrRepeatedNicknameIsNoNickname() throws {
        XCTAssertNil(try parcel(displayName: "   ").nickname)
        XCTAssertNil(try parcel(displayName: "20688.13").nickname)
        XCTAssertEqual(try parcel(displayName: "  Горната  ").nickname, "Горната")
    }

    func testTheTreatmentFormsParcelsCarryTheNickname() throws {
        let json = #"{"cropType":"Maize","parcels":[{"id":"p1","name":"20688.13","displayName":"Нивата","#
            + #""cropType":"Maize","areaHa":1.5,"locationId":"l1","locationName":"Север","geometry":null}]}"#
        let crop = try JSONDecoder().decode(ParcelsByCropAPI.CropParcels.self, from: Data(json.utf8))
        XCTAssertEqual(crop.parcels.first?.parcel.title, "Нивата")
        XCTAssertEqual(crop.parcels.first?.parcel.name, "20688.13")
    }

    func testTheParcelScreenReadsTheNickname() throws {
        let with = #"{"id":"p1","name":"20688.13","displayName":"Нивата","cropType":null}"#
        let without = #"{"id":"p1","name":"20688.13","cropType":null}"#
        XCTAssertEqual(try JSONDecoder().decode(ParcelHistory.ParcelRef.self, from: Data(with.utf8)).nickname, "Нивата")
        XCTAssertNil(try JSONDecoder().decode(ParcelHistory.ParcelRef.self, from: Data(without.utf8)).nickname)
    }

    /// Clearing a nickname must SEND a null — an absent key is "no change"
    /// to the server, and the parcel would keep the old name.
    func testClearingSendsNullNotNothing() throws {
        let cleared = try JSONEncoder().encode(["displayName": String?.none])
        XCTAssertEqual(String(decoding: cleared, as: UTF8.self), #"{"displayName":null}"#)
        let set = try JSONEncoder().encode(["displayName": String?.some("Нивата")])
        XCTAssertEqual(String(decoding: set, as: UTF8.self), #"{"displayName":"Нивата"}"#)
    }
}
