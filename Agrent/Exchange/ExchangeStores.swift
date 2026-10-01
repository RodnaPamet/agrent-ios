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
            await CachedResource.loadShowingCacheFirst(ExchangeAPI.listingsPath(first)) { data in
                try await ExchangeAPI.decodeListings(from: data)
            } publish: { [weak self] in self?.apply($0) }
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
        await CachedResource.loadShowingCacheFirst(ExchangeAPI.myListingsPath) { data in
            try await ExchangeAPI.decodeMyListings(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}

@Observable
@MainActor
final class MyInquiriesStore {
    private(set) var state: LoadState<[ExchangeInquiry]> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        await CachedResource.loadShowingCacheFirst(ExchangeAPI.inquiriesPath) { data in
            try await ExchangeAPI.decodeInquiries(from: data)
        } publish: { [weak self] in self?.state = $0 }
    }
}
