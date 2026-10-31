import Foundation
import Observation

/// Your own listing's two status moves (#478, owner 2026-10-31): «Оттегли»
/// and «Изпълнена», on the listing's screen, which a row of «Моите обяви»
/// now opens.
///
/// ── What the server allows (agri-saas `assertListingTransition`) ──
///
/// ACTIVE and EXPIRED are the states a seller can still act on; WITHDRAWN
/// and FULFILLED are TERMINAL and never come back. Withdrawing is allowed
/// from either live state; fulfilling only from ACTIVE, because an expired
/// listing sold nothing on the board. So the buttons are offered exactly
/// where pressing them would succeed, and a refusal the server still sends
/// (the listing expired while the screen was open) is shown as a sentence.
///
/// ── What fulfilling does besides ──
///
/// The server declines every PENDING inquiry on the listing and tells each
/// buyer, so the question says so: a seller should not learn it from a
/// buyer's reply.
enum ListingCustodyAction: String, Encodable, CaseIterable, Sendable {
    case fulfil = "FULFILLED"
    case withdraw = "WITHDRAWN"

    /// The moves offered for this listing, in the order they are shown:
    /// none on another farm's listing, for a person who may not write, or on
    /// a terminal one.
    nonisolated static func offered(status: ExchangeListingStatus, isOwn: Bool, mayWrite: Bool)
        -> [ListingCustodyAction] {
        guard isOwn, mayWrite else { return [] }
        switch status {
        case .active: return [.fulfil, .withdraw]
        case .expired: return [.withdraw]
        case .fulfilled, .withdrawn, .unknown: return []
        }
    }

    var title: String {
        switch self {
        case .fulfil: "Изпълнена"
        case .withdraw: "Оттегли"
        }
    }

    /// Voice Control: the Bulgarian word first, as on every button.
    var spokenNames: [String] {
        switch self {
        case .fulfil: A11y.spokenNames("Изпълнена", "Fulfilled")
        case .withdraw: A11y.spokenNames("Оттегли", "Withdraw")
        }
    }

    var confirmTitle: String {
        switch self {
        case .fulfil: "Да се отбележи ли обявата като изпълнена?"
        case .withdraw: "Да се оттегли ли обявата?"
        }
    }

    var confirmMessage: String {
        switch self {
        case .fulfil:
            "Обявата излиза от Борсата. Чакащите запитвания по нея се отказват и купувачите получават известие. Това не може да се отмени."
        case .withdraw:
            "Обявата излиза от Борсата. Разговорите по нея остават. Това не може да се отмени."
        }
    }

    /// Said once the server has taken it.
    var done: String {
        switch self {
        case .fulfil: "Обявата е отбелязана като изпълнена."
        case .withdraw: "Обявата е оттеглена."
        }
    }
}

/// `PATCH /exchange/listings/{id}`'s answer: the id and the new status only.
struct ListingStatusChanged: Decodable, Equatable, Sendable {
    let id: String
    let status: ExchangeListingStatus
}

/// The listing screen's status, and the one move in flight.
@MainActor
@Observable
final class ListingCustody {
    private(set) var status: ExchangeListingStatus
    private(set) var sending: ListingCustodyAction?
    private(set) var failure: String?
    /// The sentence for VoiceOver after a move the server took.
    private(set) var done: String?

    private let send: @MainActor (String, ListingCustodyAction) async throws -> ListingStatusChanged

    init(status: ExchangeListingStatus,
         send: @escaping @MainActor (String, ListingCustodyAction) async throws -> ListingStatusChanged
            = { try await ExchangeAPI.setListingStatus($0, $1) }) {
        self.status = status
        self.send = send
    }

    /// The status an edit left (#478): an expired listing given a later
    /// date comes back ACTIVE, and its buttons with it.
    func adopt(_ status: ExchangeListingStatus) {
        self.status = status
    }

    /// The confirmed move. One at a time: the second button is disabled
    /// while the first is out, and a terminal answer leaves nothing to press.
    func perform(_ action: ListingCustodyAction, listingID: String) async {
        guard sending == nil else { return }
        sending = action
        failure = nil
        done = nil
        defer { sending = nil }
        do {
            let changed = try await send(listingID, action)
            status = changed.status
            done = action.done
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
