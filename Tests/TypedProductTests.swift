import XCTest
@testable import Agrent

/// The spray sheet's typed product (#237): what a name is against the farm's
/// catalogue, and what goes on the wire for it. The match must agree with
/// agri-saas's unique index — `lower(name)` per farm — or a farmer meets
/// `PESTICIDE_REGULATORY_FIELDS_REQUIRED` in a field. Synthetic names only.
final class TypedProductTests: XCTestCase {

    private func item(_ name: String, _ category: String = "PESTICIDE", sample: Bool = false) -> InputItem {
        InputItem(id: "itm_\(name)", name: name, category: category, defaultUnit: nil,
                  createdByUserId: sample ? nil : "usr_1", serverIsArchetype: sample)
    }

    private lazy var catalogue = [
        item("Синтетик Зеон 5 CS"),
        item("Синтетична селитра", "FERTILIZER"),
        item("Синтетична вар", "AMENDMENT"),
        item("Generic MAP 11-52-0", "FERTILIZER", sample: true),
    ]

    // MARK: - What a name is

    func testNothingTypedIsEmpty() {
        XCTAssertEqual(TypedProduct.classify("  \n", spraying: true, catalogue: catalogue), .empty)
    }

    /// Case folded, typed text trimmed — `lower(name)`, as the server's
    /// index compares it.
    func testTheFarmsProductIsFoundAsTheServerFindsIt() {
        XCTAssertEqual(TypedProduct.classify("  синтетик зеон 5 cs ", spraying: true, catalogue: catalogue),
                       .existing(catalogue[0]))
    }

    /// NOT diacritic-folded. «й» is not «и» to the server, and folding would
    /// hide the registration fields for a name it is about to create.
    func testDiacriticsAreNotFolded() {
        let withShortI = [item("Синтетичен майор")]
        XCTAssertEqual(TypedProduct.classify("синтетичен майор", spraying: true, catalogue: withShortI),
                       .existing(withShortI[0]))
        XCTAssertEqual(TypedProduct.classify("синтетичен маиор", spraying: true, catalogue: withShortI), .new)
    }

    /// A stored name is compared AS STORED. Trimming it too would match a
    /// name the server does not — and hide the fields when it creates.
    func testAStoredNameIsComparedAsStored() {
        XCTAssertEqual(TypedProduct.classify("Синтетик", spraying: true, catalogue: [item("Синтетик ")]), .new)
    }

    func testANameTheFarmDoesNotHaveIsNew() {
        XCTAssertEqual(TypedProduct.classify("Нов синтетичен препарат", spraying: true, catalogue: catalogue), .new)
    }

    /// The server's rule is ONE-SIDED: the fertiliser path takes only a
    /// fertiliser, the product path anything — a fertiliser included, since
    /// liquid nitrogen goes through a sprayer, and a lime application
    /// (AMENDMENT) as it always has. Refusing a fertiliser on the spray path
    /// would be stricter than the server and stop real work.
    func testTheKindRuleIsOneSided() {
        XCTAssertEqual(TypedProduct.classify("Синтетична селитра", spraying: true, catalogue: catalogue),
                       .existing(catalogue[1]))
        XCTAssertEqual(TypedProduct.classify("Синтетик Зеон 5 CS", spraying: false, catalogue: catalogue),
                       .wrongKind(catalogue[0]))
        XCTAssertEqual(TypedProduct.classify("Синтетична вар", spraying: true, catalogue: catalogue),
                       .existing(catalogue[2]))
        XCTAssertEqual(TypedProduct.classify("Синтетична вар", spraying: false, catalogue: catalogue),
                       .wrongKind(catalogue[2]))
        XCTAssertEqual(TypedProduct.classify("Синтетична селитра", spraying: false, catalogue: catalogue),
                       .existing(catalogue[1]))
    }

    /// A seeded archetype is never sent: a line planned with one can never
    /// be completed (agri-saas #1078). The farm's own row wins a shared name.
    func testASampleIsNeverSent() {
        XCTAssertEqual(TypedProduct.classify("generic map 11-52-0", spraying: false, catalogue: catalogue),
                       .sample(catalogue[3]))
        let shared = [item("Синтетик", sample: true), item("синтетик")]
        XCTAssertEqual(TypedProduct.classify("Синтетик", spraying: true, catalogue: shared), .existing(shared[1]))
    }

    /// `max(200)` as JavaScript counts — UTF-16 units — on the trimmed name.
    func testANameIsAtMostTwoHundredUnits() {
        XCTAssertFalse(TypedProduct.isTooLong(String(repeating: "я", count: 200)))
        XCTAssertTrue(TypedProduct.isTooLong(String(repeating: "я", count: 201)))
        XCTAssertFalse(TypedProduct.isTooLong("  " + String(repeating: "я", count: 200) + "\n"),
                       "trimmed first, as the server trims")
    }

    /// A 409 on this route is the typed name colliding with a kept sample,
    /// NOT the app-wide stale edit (#240).
    func testAConflictIsSaidAsTheNameNotAStaleEdit() {
        let text = CreateFieldOperation.failureText(
            APIClient.APIError.conflict(currentVersion: nil, expectedVersion: nil))
        XCTAssertTrue(text.contains("образцов продукт"), text)
        XCTAssertFalse(text.contains("променен"), text)
        // Positive control: anything else is said as everywhere else.
        XCTAssertEqual(CreateFieldOperation.failureText(URLError(.notConnectedToInternet)),
                       UserMessage.text(for: URLError(.notConnectedToInternet)))
    }

    // MARK: - Suggestions

    /// The spray path takes any of the farm's products, so it offers any;
    /// the fertiliser path offers fertilisers.
    func testSuggestionsAreTheFarmsOwnThatThisPathTakes() {
        XCTAssertEqual(TypedProduct.suggestions(for: "синт", spraying: true, in: catalogue).map(\.name),
                       ["Синтетик Зеон 5 CS", "Синтетична вар", "Синтетична селитра"])
        XCTAssertEqual(TypedProduct.suggestions(for: "синт", spraying: false, in: catalogue).map(\.name),
                       ["Синтетична селитра"])
        // Never a sample, never for one letter, never once the name is whole.
        XCTAssertEqual(TypedProduct.suggestions(for: "map", spraying: false, in: catalogue), [])
        XCTAssertEqual(TypedProduct.suggestions(for: "с", spraying: true, in: catalogue), [])
        XCTAssertEqual(TypedProduct.suggestions(for: "синтетик зеон 5 cs", spraying: true, in: catalogue), [])
    }

    // MARK: - On the wire

    private func json(_ draft: CreateFieldOperation) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    }

    private func spray(_ name: String, _ registration: CreateFieldOperation.NewProductRegistration?,
                       category: CreateFieldOperation.NewProductCategory? = nil) -> CreateFieldOperation {
        CreateFieldOperation(operationType: "SPRAY", parcelIds: ["p1"], assigneeUserId: "u1",
                             productName: name, doseValue: 2, doseUnitId: "unt_l",
                             waterRateValue: nil, waterRateUnitId: nil,
                             fertilizerName: nil, fertilizerDoseValue: nil, fertilizerDoseUnitId: nil,
                             newProductCategory: category, newProductRegistration: registration,
                             applicationTechnique: "boom", targetNote: nil)
    }

    /// A new name under «Пръскане» says what it is (agri-saas #1499): a
    /// fertiliser — liquid nitrogen through a sprayer — goes as FERTILIZER
    /// with no registration; a plant protection product as PESTICIDE with it.
    /// A match carries neither.
    func testANewSprayProductSaysWhatItIs() throws {
        let fertiliser = try json(spray("Синтетичен течен тор", nil, category: .fertilizer))
        XCTAssertEqual(fertiliser["newProductCategory"] as? String, "FERTILIZER")
        XCTAssertNil(fertiliser["newProductRegistration"], "a fertiliser has no ПРЗ №")

        let pesticide = try json(spray("Нов синтетичен препарат",
                                       .init(pppRegistrationNo: "0000-ПРЗ", quarantinePeriodDays: 14),
                                       category: .pesticide))
        XCTAssertEqual(pesticide["newProductCategory"] as? String, "PESTICIDE")
        XCTAssertNotNil(pesticide["newProductRegistration"])

        let known = try json(spray("Синтетик Зеон 5 CS", nil))
        XCTAssertNil(known["newProductCategory"], "a match must not say what it becomes")
    }

    /// By name, never by id — within a kind both is `OPERATION_INPUT_AMBIGUOUS`
    /// — and the registration only when there is one to send.
    func testTheProductGoesByNameAndTheRegistrationOnlyWhenNew() throws {
        let known = try json(spray("Синтетик Зеон 5 CS", nil))
        XCTAssertEqual(known["productName"] as? String, "Синтетик Зеон 5 CS")
        XCTAssertNil(known["productItemId"])
        XCTAssertNil(known["newProductRegistration"], "a match must not carry a registration")

        let new = try json(spray("Нов синтетичен препарат",
                                 .init(pppRegistrationNo: "0000-ПРЗ", quarantinePeriodDays: 14)))
        let registration = try XCTUnwrap(new["newProductRegistration"] as? [String: Any])
        XCTAssertEqual(registration["pppRegistrationNo"] as? String, "0000-ПРЗ")
        XCTAssertEqual(registration["quarantinePeriodDays"] as? Int, 14)
    }

    // MARK: - Archetypes (moved from the product form this replaced)

    private func decoded(_ name: String, createdBy: String? = nil, category: String = "PESTICIDE") throws -> InputItem {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "i", "name": name, "category": category, "createdByUserId": createdBy as Any,
        ])
        return try JSONDecoder().decode(InputItem.self, from: json)
    }

    /// Provenance, not the name: a seeded row has no creator.
    func testArchetypesAreThoseWithNoCreator() throws {
        XCTAssertTrue(try decoded("Generic MAP 11-52-0").isArchetype)
        XCTAssertFalse(try decoded("Синтетик", createdBy: "u1").isArchetype)
    }

    /// A real product whose trade name happens to start with the word is
    /// theirs; a seeded row that does not start with it is still seeded.
    func testTheNameIsNotTheSignal() throws {
        XCTAssertFalse(try decoded("Generic Glyphosate 360", createdBy: "u1").isArchetype)
        XCTAssertTrue(try decoded("Компост", category: "AMENDMENT").isArchetype)
    }

    /// The split stays a NEGATION — see `testTheKindIsTheServersComplementRule`.
    func testOnlyAFertiliserIsAFertiliser() throws {
        XCTAssertFalse(try decoded("Синтетична вар", category: "AMENDMENT").isFertilizer)
        XCTAssertTrue(try decoded("Синтетична селитра", category: "FERTILIZER").isFertilizer)
    }
}
