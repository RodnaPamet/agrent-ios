import Foundation
import Observation

@Observable
@MainActor
final class ExchangeListingsStore {
    private(set) var state: LoadState<ExchangeListingPage> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(ExchangeAPI.listingsPath) { data in
            try await ExchangeAPI.decodeListings(from: data)
        }
    }
}

@Observable
@MainActor
final class MyListingsStore {
    private(set) var state: LoadState<[OwnExchangeListing]> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(ExchangeAPI.myListingsPath) { data in
            try await ExchangeAPI.decodeMyListings(from: data)
        }
    }
}

@Observable
@MainActor
final class MyInquiriesStore {
    private(set) var state: LoadState<[ExchangeInquiry]> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(ExchangeAPI.inquiriesPath) { data in
            try await ExchangeAPI.decodeInquiries(from: data)
        }
    }
}

/// The compose sheet's own state.
@Observable
@MainActor
final class InquiryComposer {
    enum Phase: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    private(set) var phase: Phase = .editing
    var message: String = ""

    var canSend: Bool {
        phase == .editing && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(listingID: String) async {
        phase = .sending
        do {
            _ = try await ExchangeAPI.createInquiry(
                listingID: listingID,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            phase = .sent
        } catch APIClient.APIError.conflict {
            // A CONFLICT HERE IS A SUCCESS, and this is the one place where
            // the obvious UI is wrong.
            //
            // The server enforces one inquiry per tenant per listing with a
            // unique index, and the usecase turns the duplicate-key error into
            // a conflict. So a retry of a write that SUCCEEDED but whose
            // response was lost — the ordinary case on a tractor — comes back
            // as a conflict, every time, identically. Showing it as a failure
            // tells an operator their inquiry did not send when it did, and
            // they can never retry it away.
            //
            // This is #921 inverted: there a 409 was read as success and
            // parked a write; here a success-equivalent would be read as
            // failure.
            phase = .sent
        } catch {
            phase = .failed(UserMessage.text(for: error))
        }
    }
}
