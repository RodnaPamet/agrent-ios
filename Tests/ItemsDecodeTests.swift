import XCTest
@testable import Agrent

/// `/items` returned 17KB and produced ZERO products, for as long as the
/// spray sheet has existed.
///
/// ── Why every existing test passed ──
///
/// `InputItemTests` builds items with `InputItem(id:name:category:…)`. It
/// exercises the category split and never decodes a payload, so the model
/// was verified against itself. The one thing that could have caught this
/// — running the real bytes through the real decoder — was the one thing
/// nothing did.
///
/// The bytes below are captured from production, trimmed to three rows and
/// with the tenant id removed. What matters is the shape, and the shape is
/// the whole bug.
final class ItemsDecodeTests: XCTestCase {

    /// `defaultUnit` here has NO `name`. Measured: 24 of 24 rows.
    private let captured = """
    [{"id":"item-PROD-2,4-D-500","name":"Generic 2,4-D Amine 500 SL",
      "category":"PESTICIDE","sku":"PROD-2,4-D-500","createdByUserId":null,
      "defaultUnit":{"id":"u-l","key":"litre","symbol":"л","measure":"VOLUME"}},
     {"id":"item-FERT-UREA","name":"Generic Urea 46-0-0","category":"FERTILIZER",
      "createdByUserId":null,
      "defaultUnit":{"id":"u-kg","key":"kilogram","symbol":"кг","measure":"MASS"}},
     {"id":"item-USER-1","name":"Roubdup","category":"PESTICIDE",
      "createdByUserId":"cmqwluxaj000001tip7a1fwh0","defaultUnit":null}]
    """

    func testTheRealPayloadDecodes() async throws {
        let items = try await LocationsAPI.decodeItems(from: Data(captured.utf8))
        XCTAssertEqual(items.count, 3, "a nested unit took the whole array with it")
        XCTAssertEqual(items[0].name, "Generic 2,4-D Amine 500 SL")
    }

    /// The exact failure. `/units` sends `name`; `/items[].defaultUnit`
    /// does not — a shape is a property of an ENDPOINT, not of a type.
    func testANestedUnitWithoutANameIsFine() async throws {
        let items = try await LocationsAPI.decodeItems(from: Data(captured.utf8))
        let unit = try XCTUnwrap(items[0].defaultUnit)
        XCTAssertNil(unit.name)
        XCTAssertEqual(unit.symbol, "л")
        XCTAssertEqual(unit.pickerLabel, "л", "a missing name must not render as empty")
    }

    /// …and the `/units` shape, which DOES carry a name, still works —
    /// the positive control. Making `name` optional must not have been a
    /// change that "fixes" one endpoint by ignoring the other.
    func testTheUnitsEndpointShapeStillCarriesItsName() async throws {
        let json = """
        [{"id":"u-l-da","key":"litre_per_decare","name":"литър на декар",
          "symbol":"л/дка","measure":"RATE"}]
        """
        let units = try await LocationsAPI.decodeUnits(from: Data(json.utf8))
        XCTAssertEqual(units.first?.name, "литър на декар")
        XCTAssertEqual(units.first?.pickerLabel, "литър на декар (л/дка)")
    }

    /// A genuinely absent unit is still absent, not a decode failure.
    func testANullDefaultUnitIsNil() async throws {
        let items = try await LocationsAPI.decodeItems(from: Data(captured.utf8))
        XCTAssertNil(items[2].defaultUnit)
        XCTAssertEqual(items[2].name, "Roubdup")
    }

    /// Provenance survives the same payload — the two facts this app reads
    /// off `/items` are the name and who made the row.
    func testProvenanceIsReadFromTheSamePayload() async throws {
        let items = try await LocationsAPI.decodeItems(from: Data(captured.utf8))
        XCTAssertTrue(items[0].isArchetype)
        XCTAssertTrue(items[1].isArchetype)
        XCTAssertFalse(items[2].isArchetype)
    }
}
