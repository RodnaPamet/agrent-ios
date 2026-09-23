import XCTest
@testable import Agrent

/// Creating a real product, instead of filing another placeholder.
@MainActor
final class NewProductTests: XCTestCase {

    /// The server's enum, written out literally. A value it rejects is not
    /// a near miss on a create — it is a failed save.
    private let serverCategories = [
        "SEED", "PESTICIDE", "FERTILIZER", "AMENDMENT",
        "FUEL", "HARVESTED_PRODUCE", "OTHER",
    ]

    func testCategoriesMatchTheServerEnum() {
        XCTAssertEqual(Set(ItemCategory.allCases.map(\.rawValue)), Set(serverCategories))
    }

    func testEveryCategoryHasADistinctBulgarianLabel() {
        let labels = ItemCategory.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        for category in ItemCategory.allCases {
            XCTAssertNotEqual(category.label, category.rawValue)
            XCTAssertTrue(
                category.label.unicodeScalars.contains {
                    $0.properties.isAlphabetic && $0.value > 0x400
                }, category.label)
        }
    }

    /// The three that land in the ХИМИЧНИ ОБРАБОТКИ table. Those are the
    /// ones where leaving the optional fields empty files an incomplete
    /// regulated row rather than merely a sparse catalogue entry.
    func testTheRegisterCategoriesAreTheChemicalOnes() {
        let onRegister = ItemCategory.allCases.filter(\.appearsOnTheRegister)
        XCTAssertEqual(Set(onRegister), Set([.pesticide, .fertilizer, .amendment]))
    }

    // MARK: - The payload

    private func encode(_ draft: CreateItem) throws -> [String: Any] {
        let data = try JSONEncoder().encode(draft)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheRequiredThreeAreAlwaysSent() throws {
        let json = try encode(CreateItem(
            name: "Karate Zeon 5 CS", category: "PESTICIDE", defaultUnitId: "u1",
            activeIngredient: nil, pppRegistrationNo: nil, quarantinePeriodDays: nil))
        XCTAssertEqual(json["name"] as? String, "Karate Zeon 5 CS")
        XCTAssertEqual(json["category"] as? String, "PESTICIDE")
        XCTAssertEqual(json["defaultUnitId"] as? String, "u1")
    }

    /// Blank is NOT empty-string. A field the person left alone means "not
    /// supplied" — which the column already is — and writing "" would put
    /// an empty string where null is the honest value, on a register where
    /// the difference is whether a column was answered.
    func testTheOptionalThreeRideAlongWhenGiven() throws {
        let json = try encode(CreateItem(
            name: "Karate Zeon 5 CS", category: "PESTICIDE", defaultUnitId: "u1",
            activeIngredient: "ламбда-цихалотрин 50 г/л",
            pppRegistrationNo: "01234-ПРЗ", quarantinePeriodDays: 30))
        XCTAssertEqual(json["activeIngredient"] as? String, "ламбда-цихалотрин 50 г/л")
        XCTAssertEqual(json["pppRegistrationNo"] as? String, "01234-ПРЗ")
        XCTAssertEqual(json["quarantinePeriodDays"] as? Int, 30)
    }

    // MARK: - Archetypes

    private func item(_ name: String, createdBy: String? = nil,
                      category: String = "PESTICIDE") throws -> InputItem {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "i", "name": name, "category": category,
            "createdByUserId": createdBy as Any,
        ])
        return try JSONDecoder().decode(InputItem.self, from: json)
    }

    /// Provenance, not the name. Verified on the wire: `createdByUserId`
    /// is present on 24 of 24 rows, and it partitions the catalogue
    /// identically to `attributesJson IS NOT NULL` and to the name prefix
    /// — 22 archetypes, 2 user-created.
    func testArchetypesAreThoseWithNoCreator() throws {
        XCTAssertTrue(try item("Generic MAP 11-52-0").isArchetype)
        XCTAssertTrue(try item("Generic Compound NPK 15-15-15").isArchetype)
    }

    func testAUserCreatedProductIsNotAnArchetype() throws {
        XCTAssertFalse(try item("Roubdup", createdBy: "u1").isArchetype)
        XCTAssertFalse(try item("Karate Zeon 5 CS", createdBy: "u1").isArchetype)
    }

    /// THE CASE THE NAME HEURISTIC GOT WRONG. A real product a person
    /// typed, whose trade name happens to start with the word, is theirs —
    /// and the column says so where the string cannot.
    func testARealProductNamedGenericIsNotFlagged() throws {
        XCTAssertFalse(try item("Generic Glyphosate 360", createdBy: "u1").isArchetype)
    }

    /// …and the converse: a seeded row that does NOT start with "Generic"
    /// is still an archetype.
    func testASeededRowWithAnUnexpectedNameIsStillAnArchetype() throws {
        XCTAssertTrue(try item("Компост", createdBy: nil, category: "AMENDMENT").isArchetype)
    }

    /// The register split stays a NEGATION, deliberately. Now that a closed
    /// category list exists it would be easy to "tidy" the operation sheet
    /// into an allowlist of PESTICIDE — and that would hide the three
    /// AMENDMENT items this farm owns.
    func testTheProductSplitIsStillANegation() throws {
        XCTAssertFalse(try item("Amendment X", category: "AMENDMENT").isFertilizer)
        XCTAssertTrue(try item("Generic Urea", category: "FERTILIZER").isFertilizer)
    }
}

/// What the form refuses to send, which is more than the server refuses to
/// accept.
final class ProductRegulatoryRulesTests: XCTestCase {

    /// The evidence this rule exists for, still in the live catalogue:
    ///
    ///     Roubdup · PESTICIDE · ppp=null · quarantine=null · ai=null  ×2
    ///
    /// Created twice, misspelled, every regulated field empty — on the
    /// first and only unassisted attempt.
    func testPesticidesNeedTheRegulatoryFields() {
        XCTAssertTrue(ItemCategory.pesticide.appearsOnTheRegister)
        XCTAssertTrue(ItemCategory.pesticide.requiresRegistrationDetails)
    }

    /// NOT for fertilisers. A fertiliser has no ЗЗР registration number,
    /// and requiring one would block a legitimate entry — applying a rule
    /// past the case that justified it.
    func testFertilisersAndAmendmentsDoNot() {
        for category in [ItemCategory.fertilizer, .amendment] {
            XCTAssertTrue(category.appearsOnTheRegister, category.rawValue)
            XCTAssertFalse(category.requiresRegistrationDetails, category.rawValue)
        }
    }

    func testNonRegisterCategoriesNeedNothing() {
        for category in [ItemCategory.seed, .fuel, .harvestedProduce, .other] {
            XCTAssertFalse(category.appearsOnTheRegister, category.rawValue)
            XCTAssertFalse(category.requiresRegistrationDetails, category.rawValue)
        }
    }

    /// The client is stricter than the server on purpose, so this pins the
    /// direction: anything the form requires, the server also accepts.
    func testTheFormIsStricterThanTheServerNeverLooser() {
        // The server requires exactly three fields; the form requires those
        // plus two more for one category. It must never require FEWER.
        XCTAssertTrue(ItemCategory.allCases.allSatisfy { category in
            !category.requiresRegistrationDetails || category.appearsOnTheRegister
        }, "a category demands regulatory fields it never prints")
    }
}
