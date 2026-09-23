import XCTest
@testable import Agrent

/// The parcel sheet's write. Product XOR fertiliser, enforced server-side
/// as `OPERATION_INPUT_AMBIGUOUS` and mirrored so an operator learns
/// before the request.
final class CreateFieldOperationTests: XCTestCase {

    private func op(
        product: String? = nil, dose: Decimal? = nil, doseUnit: String? = nil,
        fertilizer: String? = nil, fDose: Decimal? = nil, fUnit: String? = nil,
        parcels: [String] = ["p1"]
    ) -> CreateFieldOperation {
        CreateFieldOperation(
            operationType: product != nil ? "SPRAY" : "FERTILIZE",
            parcelIds: parcels, assigneeUserId: "u1",
            productItemId: product, doseValue: dose, doseUnitId: doseUnit,
            waterRateValue: nil, waterRateUnitId: nil,
            fertilizerItemId: fertilizer, fertilizerDoseValue: fDose,
            fertilizerDoseUnitId: fUnit,
            applicationTechnique: "boom", targetNote: nil
        )
    }

    func testAValidSprayAndAValidFertilisationHaveNoProblems() {
        XCTAssertTrue(op(product: "i1", dose: 2, doseUnit: "u1").problems.isEmpty)
        XCTAssertTrue(op(fertilizer: "i2", fDose: 5, fUnit: "u1").problems.isEmpty)
    }

    /// XOR, both directions. Neither is as wrong as both, and the server
    /// refuses each.
    func testBothOrNeitherIsRefused() {
        XCTAssertTrue(
            op(product: "i1", dose: 2, doseUnit: "u1",
               fertilizer: "i2", fDose: 5, fUnit: "u1")
                .problems.contains(.inputAmbiguous))
        XCTAssertTrue(op().problems.contains(.inputMissing))
    }

    func testADoseNeedsBothAValueAndAUnit() {
        XCTAssertTrue(op(product: "i1", dose: 2).problems.contains(.doseMissing))
        XCTAssertTrue(op(product: "i1", doseUnit: "u1").problems.contains(.doseMissing))
        XCTAssertTrue(op(fertilizer: "i2", fDose: 5).problems.contains(.doseMissing))
    }

    /// Zero is not a dose. An application of nothing is not a record of
    /// anything, and it reaches a legally-filed register.
    func testZeroAndNegativeDosesAreRefused() {
        XCTAssertTrue(op(product: "i1", dose: 0, doseUnit: "u1")
            .problems.contains(.doseNotPositive))
        XCTAssertTrue(op(fertilizer: "i2", fDose: -1, fUnit: "u1")
            .problems.contains(.doseNotPositive))
    }

    func testAnOperationNeedsAParcel() {
        XCTAssertTrue(op(product: "i1", dose: 2, doseUnit: "u1", parcels: [])
            .problems.contains(.noParcel))
    }

    /// THE SLUG reaches the wire, never the label — `applicationTechnique`
    /// is printed VERBATIM onto the ДНЕВНИК, the filed БАБХ register.
    func testTheTechniqueGoesOutAsASlug() throws {
        let json = try String(
            data: JSONEncoder().encode(op(product: "i1", dose: 2, doseUnit: "u1")),
            encoding: .utf8)!
        XCTAssertTrue(json.contains("\"applicationTechnique\":\"boom\""), json)
        XCTAssertFalse(json.contains("Щангова"), json)
    }
}

/// `applicationTechnique` is FREE TEXT the server does not validate, and
/// production already holds `Dron` and `dron` — two casings of a value
/// that is not even the slug (`drone`). A `switch` over the seven renders
/// nothing for both existing rows.
final class ApplicationTechniqueTests: XCTestCase {

    func testSevenOptionsAllLabelledInBulgarian() {
        XCTAssertEqual(ApplicationTechnique.allCases.count, 7)
        for t in ApplicationTechnique.allCases {
            XCTAssertTrue(
                t.label.unicodeScalars.contains { $0.value > 0x400 },
                "\(t.rawValue) → \(t.label) is not Bulgarian")
        }
    }

    /// THE regression, against the two values actually in the database.
    func testTheCasingsAlreadyInProductionResolve() {
        XCTAssertEqual(ApplicationTechnique.display("drone"), "Дрон")
        XCTAssertEqual(ApplicationTechnique.display("Dron"), "Dron",
                       "not a slug, so it passes through as written")
        XCTAssertEqual(ApplicationTechnique.display("dron"), "dron")
    }

    /// Case folding on the real slugs, so a stored `BOOM` still reads.
    func testSlugLookupFoldsCase() {
        XCTAssertEqual(ApplicationTechnique.display("BOOM"), "Щангова пръскачка")
        XCTAssertEqual(ApplicationTechnique.display(" boom "), "Щангова пръскачка")
    }

    func testUnknownPassesThroughAndAbsentStaysAbsent() {
        XCTAssertEqual(ApplicationTechnique.display("helicopter"), "helicopter")
        XCTAssertNil(ApplicationTechnique.display(nil))
        XCTAssertNil(ApplicationTechnique.display("  "))
    }
}

final class InputItemTests: XCTestCase {

    private func item(_ id: String, _ category: String) -> InputItem {
        InputItem(id: id, name: "Item \(id)", category: category,
                  defaultUnit: nil, createdByUserId: nil)
    }

    /// THE split is a NEGATION. Measured on this tenant: 24 items — 13
    /// PESTICIDE, 8 FERTILIZER, **3 AMENDMENT**. Filtering products to
    /// PESTICIDE hides three the farm has catalogued.
    func testProductsAreEverythingThatIsNotFertiliser() {
        let all = [item("1", "PESTICIDE"), item("2", "FERTILIZER"),
                   item("3", "AMENDMENT")]
        let products = all.filter { !$0.isFertilizer }
        XCTAssertEqual(products.count, 2)
        XCTAssertTrue(products.contains { $0.category == "AMENDMENT" },
                      "an allowlist on PESTICIDE would have dropped this")
        XCTAssertEqual(all.filter(\.isFertilizer).count, 1)
    }

    func testTheCategoryMatchFoldsCase() {
        XCTAssertTrue(item("1", "fertilizer").isFertilizer)
    }
}

/// `/api/auth/me` closes two gaps: `assigneeUserId`, which is
/// `z.string().min(1)` and required, and the self-deactivation guard.
final class CurrentUserTests: XCTestCase {

    private func decode(_ json: String) throws -> CurrentUser {
        try JSONDecoder().decode(CurrentUser.self, from: Data(json.utf8))
    }

    func testItReadsTheNestedUser() throws {
        let me = try decode(#"""
        {"user":{"id":"u1","email":"a@b.invalid","name":"Иван","role":"EDITOR"},
         "tenant":{"id":"t1","name":"Farm","slug":"agrent"}}
        """#)
        XCTAssertEqual(me.id, "u1")
        XCTAssertEqual(me.name, "Иван")
        XCTAssertEqual(me.role, "EDITOR")
    }

    /// `tenant` is deliberately NOT modelled — it is the user's OLDEST
    /// membership, not the one they are viewing. Decoding must ignore it
    /// rather than fail, and nothing may read it.
    func testTheTenantBlockIsIgnoredNotDecoded() throws {
        let me = try decode(#"{"user":{"id":"u1"},"tenant":null}"#)
        XCTAssertEqual(me.id, "u1")
        XCTAssertNil(me.name)
    }

    /// The write gate. `createFieldOperation` requires ROLE_ORDER >= 3;
    /// MECHANISATOR is 1 and an operator's job is completion, not
    /// creation.
    func testOnlyWritingRolesAreOfferedTheSheet() {
        for role in ["OWNER", "ADMIN", "EDITOR"] {
            XCTAssertTrue(
                CurrentUser(id: "u", name: nil, email: nil, role: role)
                    .mayCreateOperations, role)
        }
        for role in ["MECHANISATOR", "READER", "AUDITOR"] {
            XCTAssertFalse(
                CurrentUser(id: "u", name: nil, email: nil, role: role)
                    .mayCreateOperations, role)
        }
    }

    /// FAILS OPEN. `role` is the oldest membership's, so it may not be
    /// the role here — and hiding a button from somebody who could have
    /// used it is worse than showing one the server refuses with a
    /// sentence they can read.
    func testAnUnknownOrAbsentRoleStillSeesTheControl() {
        XCTAssertTrue(CurrentUser(id: "u", name: nil, email: nil, role: nil)
            .mayCreateOperations)
        XCTAssertTrue(CurrentUser(id: "u", name: nil, email: nil, role: "SOMETHING_NEW")
            .mayCreateOperations)
    }
}
