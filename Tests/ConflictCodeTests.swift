import XCTest
@testable import Agrent

/// A 409 is a stale edit only when it says so (#240): `STALE_DATA`, or no
/// code at all from a server before the codes. Any other code is a collision
/// with something that exists, and keeps its code to be said as one.
final class ConflictCodeTests: XCTestCase {

    private func conflict(_ json: String) -> APIClient.APIError {
        APIClient.conflict(from: Data(json.utf8))
    }

    private func isStaleEdit(_ error: APIClient.APIError) -> Bool {
        if case .conflict = error { true } else { false }
    }

    func testAStaleEditIsStillAConflict() {
        let stale = conflict(#"{"error":{"code":"STALE_DATA","message":"changed","details":{"currentVersion":4,"expectedVersion":3}}}"#)
        guard case .conflict(let current, let expected) = stale else { return XCTFail("STALE_DATA is not a conflict") }
        XCTAssertEqual(current, 4)
        XCTAssertEqual(expected, 3)
        XCTAssertEqual(UserMessage.text(for: stale), "Записът е променен на сървъра, докато го редактирахте.")
    }

    /// A server before the codes said nothing, and its 409 was a stale edit.
    func testACodeless409IsStillAConflict() {
        XCTAssertTrue(isStaleEdit(conflict(#"{"error":{"message":"Conflict"}}"#)))
        XCTAssertTrue(isStaleEdit(conflict("<html>proxy</html>")))
    }

    /// Each keeps its code and is said as what it is, never «променен».
    func testACollisionKeepsItsCodeAndIsSaidAsOne() {
        let cases: [(String, String)] = [
            ("ITEM_NAME_ALREADY_EXISTS", "Вече има продукт с това име. Въведете друго име."),
            ("LISTING_INTEREST_ALREADY_SENT", "Вече сте изпратили запитване за тази обява."),
            // The unique-index 409 any route can raise (`toApiErrorResponse`, P2002).
            ("CONFLICT", "Това вече съществува на сървъра."),
        ]
        for (code, sentence) in cases {
            let error = conflict(#"{"error":{"code":"\#(code)","message":"A resource with that unique constraint already exists"}}"#)
            guard case .http(409, code?, _, _, _) = error else { return XCTFail("\(code) lost its code: \(error)") }
            XCTAssertEqual(UserMessage.text(for: error), sentence, code)
        }
    }

    /// A code nobody has named yet is not a stale edit either.
    func testAnUnnamedCodeIsNotAStaleEdit() {
        let error = conflict(#"{"error":{"code":"SOMETHING_NEW_EXISTS"}}"#)
        XCTAssertFalse(isStaleEdit(error))
        XCTAssertEqual(UserMessage.text(for: error), "Това вече съществува на сървъра.")
    }

    /// The outbox's keep-mine / take-server is for a stale edit only; a
    /// collision is refused, and said.
    func testTheOutboxResolvesOnlyAStaleEdit() {
        let stale = conflict(#"{"error":{"code":"STALE_DATA","details":{"currentVersion":4}}}"#)
        XCTAssertEqual(FieldOperationRules.failure(stale), .conflict(currentVersion: 4), "positive control")
        let taken = conflict(#"{"error":{"code":"CONFLICT"}}"#)
        XCTAssertEqual(FieldOperationRules.failure(taken), .refused("Това вече съществува на сървъра."))
    }

    /// The product create's own sentence, by its code now, and still for a
    /// codeless 409 from an older server.
    func testTheTakenSampleNameIsSaidOnTheOperationSheet() {
        let sample = "Това наименование е заето от образцов продукт. Въведете истинското търговско наименование."
        XCTAssertEqual(CreateFieldOperation.failureText(conflict(#"{"error":{"code":"ITEM_NAME_ALREADY_EXISTS"}}"#)), sample)
        XCTAssertEqual(CreateFieldOperation.failureText(conflict(#"{"error":{}}"#)), sample)
        XCTAssertEqual(CreateFieldOperation.failureText(conflict(#"{"error":{"code":"CONFLICT"}}"#)),
                       "Това вече съществува на сървъра.", "another collision is not the sample name")
    }
}
