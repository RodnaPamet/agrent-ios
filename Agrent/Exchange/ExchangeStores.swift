import Foundation
import Observation

@Observable
@MainActor
final class ExchangeListingsStore {
    private(set) var state: LoadState<ExchangeListingPage> = .loading
    private(set) var rows: [ExchangeListing] = []
    private(set) var nextCursor: String?
    private(set) var loadingMore = false
    private(set) var loadMoreError: String?

    /// The filter the board is currently showing.
    var query = ExchangeQuery()

    var hasMore: Bool { nextCursor != nil }

    func load() async {
        if state.value == nil { state = .loading }
        loadMoreError = nil
        let first = query.firstPage

        // ONLY THE UNFILTERED FIRST PAGE IS CACHED, and the reason is the
        // offline case rather than tidiness. `CachedResource` keys on the
        // path, so every search term would mint its own cache entry —
        // meaning an operator offline in a field could open the board and
        // be shown whatever they last searched for, presented as the
        // board. The unfiltered page is the one worth having with no
        // signal; a filtered one is a question that needs an answer.
        if first.isFiltered {
            await loadFiltered(first)
        } else {
            let loaded = await CachedResource.load(ExchangeAPI.listingsPath(first)) { data in
                try await ExchangeAPI.decodeListings(from: data)
            }
            apply(loaded)
        }
    }

    private func loadFiltered(_ query: ExchangeQuery) async {
        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.listingsPath(query))
            let page = try await ExchangeAPI.decodeListings(from: data)
            apply(.loaded(page, .fresh))
        } catch {
            apply(.failed(UserMessage.text(for: error)))
        }
    }

    private func apply(_ loaded: LoadState<ExchangeListingPage>) {
        state = loaded
        switch loaded {
        case .loaded(let page, _):
            rows = page.rows
            nextCursor = page.nextCursor
        case .failed, .loading:
            rows = []
            nextCursor = nil
        }
    }

    /// PARITY GAP 2. Never cached — see `load`. A later page is a
    /// continuation of a question, not an answer worth keeping.
    func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        loadMoreError = nil
        defer { loadingMore = false }

        var next = query
        next.cursor = cursor
        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.listingsPath(next))
            let page = try await ExchangeAPI.decodeListings(from: data)

            // De-duplicated by id: a cursor is positional, and a listing
            // posted between two fetches shifts the window so a row can
            // repeat. Two identical offers on a trading board is not
            // cosmetic — it reads as two sellers.
            var seen = Set(rows.map(\.id))
            rows += page.rows.filter { seen.insert($0.id).inserted }
            nextCursor = page.nextCursor
        } catch {
            loadMoreError = UserMessage.text(for: error)
        }
    }

    func clearFilters() async {
        query = ExchangeQuery()
        await load()
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
