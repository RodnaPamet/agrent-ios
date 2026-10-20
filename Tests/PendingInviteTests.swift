import XCTest
@testable import Agrent

/// Членове's pending invitations (#365, agri-saas #2084): read leniently,
/// and "not delivered" only when the server says the email came back.
/// Synthetic addresses.
final class PendingInviteTests: XCTestCase {
    private func read(_ json: String) async throws -> [PendingInvite] {
        try await AdminAPI.decodeInvites(from: Data(json.utf8))
    }

    func testTheFixtureIsTheServersShape() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "admin-invites", withExtension: "json"))
        let invites = try await AdminAPI.decodeInvites(from: Data(contentsOf: url))
        XCTAssertEqual(invites.map(\.email), ["operator.one@example.invalid", "returned@example.invalid"])
        XCTAssertEqual(invites[0].role, .mechanisator)
        XCTAssertEqual(invites[0].delivery, .pending)
        guard case .notDelivered(let at) = invites[1].delivery else { return XCTFail("\(invites[1].delivery)") }
        XCTAssertNotNil(at)
        XCTAssertEqual(invites[1].invitedBy?.name, "Тестов Стопанин")
    }

    /// `null` is "nothing came back", never "delivered"; every token, known
    /// or not, is "not delivered".
    func testOnlyATokenMeansNotDelivered() async throws {
        let rows = try await read(#"""
            [{"id":"a","email":"a@example.invalid","role":"READER","inviteDelivery":null},
             {"id":"b","email":"b@example.invalid","role":"READER","inviteDelivery":"COMPLAINED"},
             {"id":"c","email":"c@example.invalid","role":"READER","inviteDelivery":"SOMETHING_NEW"},
             {"id":"d","email":"d@example.invalid","role":"READER","inviteDelivery":"  "}]
            """#)
        XCTAssertEqual(rows.map(\.delivery), [.pending, .notDelivered(nil), .notDelivered(nil), .pending])
    }

    /// One row without an id or an address is left out, not the list; a
    /// row missing a date or carrying an unknown role is kept.
    func testOneBadRowDoesNotHideTheRest() async throws {
        let rows = try await read(#"""
            [{"email":"no-id@example.invalid"},
             {"id":"x","email":"kept@example.invalid","role":"NEW_ROLE","expiresAt":"not a date"}]
            """#)
        XCTAssertEqual(rows.map(\.id), ["x"])
        XCTAssertEqual(rows[0].role, .unknown)
        XCTAssertNil(rows[0].expiresAt)
    }

    func testTheNotesAreSentences() {
        XCTAssertTrue(MembersView.notDeliveredNote.hasSuffix("."))
        XCTAssertTrue(MembersView.pendingNote.hasSuffix("."))
    }
}
