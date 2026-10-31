import XCTest
@testable import Agrent

/// Your own listing from «Моите обяви», and its «Изпълнена» / «Оттегли»
/// (#478, owner 2026-10-31). Nothing here reaches the server: the move's
/// `send` is injected, and the first real press is the owner's.
@MainActor
final class ListingCustodyTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    // MARK: - Which moves are offered

    /// The server's state machine: both from ACTIVE, only withdrawing from
    /// EXPIRED, nothing from a terminal state.
    func testTheMovesFollowTheServersStateMachine() {
        XCTAssertEqual(ListingCustodyAction.offered(status: .active, isOwn: true, mayWrite: true), [.fulfil, .withdraw])
        XCTAssertEqual(ListingCustodyAction.offered(status: .expired, isOwn: true, mayWrite: true), [.withdraw])
        for terminal in [ExchangeListingStatus.withdrawn, .fulfilled, .unknown] {
            XCTAssertEqual(ListingCustodyAction.offered(status: terminal, isOwn: true, mayWrite: true), [], "\(terminal)")
        }
    }

    func testNothingOnAnotherFarmsListingOrForAReader() {
        XCTAssertEqual(ListingCustodyAction.offered(status: .active, isOwn: false, mayWrite: true), [])
        XCTAssertEqual(ListingCustodyAction.offered(status: .active, isOwn: true, mayWrite: false), [])
    }

    /// Every word a person reads or says is Bulgarian, and the fulfil
    /// question says what happens to the buyers waiting on an answer.
    func testTheWordsAreBulgarianAndTheFulfilQuestionNamesTheBuyers() {
        for action in ListingCustodyAction.allCases {
            for text in [action.title, action.confirmTitle, action.confirmMessage, action.done] {
                XCTAssertTrue(text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, text)
            }
            XCTAssertEqual(action.spokenNames.first, action.title, "Voice Control: the Bulgarian name first")
        }
        XCTAssertTrue(ListingCustodyAction.fulfil.confirmMessage.contains("купувачите получават известие"))
    }

    // MARK: - The wire

    func testTheBodyIsTheServersAction() throws {
        let body = try JSONEncoder().encode(["action": ListingCustodyAction.withdraw])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"action":"WITHDRAWN"}"#)
        let fulfil = try JSONEncoder().encode(["action": ListingCustodyAction.fulfil])
        XCTAssertEqual(String(decoding: fulfil, as: UTF8.self), #"{"action":"FULFILLED"}"#)
    }

    func testTheAnswerIsTheIdAndTheNewStatus() async throws {
        let changed = try await APIClient.shared.decode(Data(#"{"id":"lst_synthetic","status":"WITHDRAWN"}"#.utf8),
                                                        as: ListingStatusChanged.self)
        XCTAssertEqual(changed, ListingStatusChanged(id: "lst_synthetic", status: .withdrawn))
    }

    func testThePathIsTheListingsOwn() {
        XCTAssertTrue(ExchangeAPI.listingPath("lst_synthetic").hasSuffix("/exchange/listings/lst_synthetic"))
    }

    // MARK: - Pressing it

    func testAMoveTheServerTookChangesTheStatusAndSaysSo() async {
        var sent: [(String, ListingCustodyAction)] = []
        let custody = ListingCustody(status: .active) { id, action in
            sent.append((id, action))
            return ListingStatusChanged(id: id, status: .fulfilled)
        }
        await custody.perform(.fulfil, listingID: "lst_synthetic")
        XCTAssertEqual(sent.map(\.0), ["lst_synthetic"])
        XCTAssertEqual(sent.map(\.1), [.fulfil])
        XCTAssertEqual(custody.status, .fulfilled)
        XCTAssertEqual(custody.done, "Обявата е отбелязана като изпълнена.")
        XCTAssertNil(custody.failure)
        XCTAssertNil(custody.sending)
        XCTAssertEqual(ListingCustodyAction.offered(status: custody.status, isOwn: true, mayWrite: true), [],
                       "a fulfilled listing offers nothing more")
    }

    /// The listing expired while the screen was open: the server refuses,
    /// the status stays what the screen knew, and the refusal is a sentence
    /// in Bulgarian, not the server's English.
    func testARefusalKeepsTheStatusAndSaysWhyInBulgarian() async {
        let custody = ListingCustody(status: .active) { _, _ in
            throw APIClient.APIError.http(status: 400, code: "VALIDATION_ERROR",
                                          message: "listing_not_active")
        }
        await custody.perform(.fulfil, listingID: "lst_synthetic")
        XCTAssertEqual(custody.status, .active)
        XCTAssertNil(custody.done)
        let failure = custody.failure ?? ""
        XCTAssertTrue(failure.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, failure)
        XCTAssertFalse(failure.contains("listing_not_active"), failure)
    }

    // MARK: - The row opens the listing

    /// A row of «Моите обяви» becomes the listing its screen shows: the
    /// same values, and still yours.
    func testARowOfMyListingsIsTheListingsOwnScreen() async throws {
        let rows = try await APIClient.shared.decode(fixture("exchange-my-listings"), as: [OwnExchangeListing].self)
        let own = try XCTUnwrap(rows.first)
        let listing = ExchangeListing(own: own)
        XCTAssertEqual(listing.id, own.id)
        XCTAssertEqual(listing.status, own.status)
        XCTAssertEqual(listing.commodity, own.commodity)
        XCTAssertEqual(listing.quantityTonnes, own.quantityTonnes)
        XCTAssertEqual(listing.pricePerTonne, own.pricePerTonne)
        XCTAssertEqual(listing.expiresAt, own.expiresAt)
        XCTAssertTrue(listing.isOwn)
        XCTAssertNil(listing.farmHandle)
    }
}
