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

    /// The query the board last asked the server, so the farm section can
    /// ask the directory the same question (`BoardFarmSearch`) — on a
    /// search, a map tap or a clear, not on every keystroke in the field.
    private(set) var lastAsked: ExchangeQuery?

    /// The first-page query that produced the rows ON SCREEN and their
    /// `nextCursor` (#673). Not `query`: that is bound live to the search
    /// field and only asked on submit, so it can hold a term nobody has
    /// searched for yet. Paging must continue the question that was answered.
    private(set) var shownQuery: ExchangeQuery?

    func load() async {
        if state.value == nil { state = .loading }
        loadMoreError = nil
        let first = query.firstPage
        lastAsked = first

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
            } publish: { [weak self] in self?.apply($0, for: first) }
        }
    }

    private func loadFiltered(_ query: ExchangeQuery) async {
        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.listingsPath(query))
            let page = try await ExchangeAPI.decodeListings(from: data)
            apply(.loaded(page, .fresh), for: query)
        } catch {
            apply(.failed(UserMessage.text(for: error)), for: query)
        }
    }

    private func apply(_ loaded: LoadState<ExchangeListingPage>, for asked: ExchangeQuery) {
        // An answer to a question that is no longer the latest one asked is
        // dropped (#673): change a filter twice quickly and the slower first
        // answer would otherwise land after the second and replace it.
        guard Self.isCurrent(asked: asked, latest: lastAsked) else { return }
        state = loaded
        switch loaded {
        case .loaded(let page, _):
            rows = page.rows
            nextCursor = page.nextCursor
            shownQuery = asked
        case .failed, .loading:
            rows = []
            nextCursor = nil
            shownQuery = nil
        }
    }

    /// Whether an answer still belongs on screen: it answers the latest
    /// first-page question asked.
    nonisolated static func isCurrent(asked: ExchangeQuery, latest: ExchangeQuery?) -> Bool {
        asked == latest
    }

    /// The request for the page after the one on screen: the question that
    /// produced it, with its cursor — never the live, possibly unsubmitted,
    /// `query` (#673). Nil when there is nothing to continue.
    nonisolated static func nextPage(shown: ExchangeQuery?, cursor: String?) -> ExchangeQuery? {
        guard var next = shown, let cursor else { return nil }
        next.cursor = cursor
        return next
    }

    /// PARITY GAP 2. Never cached — see `load`. A later page is a
    /// continuation of a question, not an answer worth keeping.
    func loadMore() async {
        guard !loadingMore, let shown = shownQuery,
              let next = Self.nextPage(shown: shown, cursor: nextCursor) else { return }
        loadingMore = true
        loadMoreError = nil
        defer { loadingMore = false }

        do {
            let data = try await APIClient.shared.data(for: ExchangeAPI.listingsPath(next))
            let page = try await ExchangeAPI.decodeListings(from: data)
            // A new search replaced the list while this page was in flight:
            // its rows belong to a list that is no longer on screen.
            guard shownQuery == shown, nextCursor == next.cursor else { return }

            // De-duplicated by id: a cursor is positional, and a listing
            // posted between two fetches shifts the window so a row can
            // repeat. Two identical offers on a trading board is not
            // cosmetic — it reads as two sellers.
            var seen = Set(rows.map(\.id))
            rows += page.rows.filter { seen.insert($0.id).inserted }
            nextCursor = page.nextCursor
        } catch {
            guard shownQuery == shown else { return }
            loadMoreError = UserMessage.text(for: error)
        }
    }

    func clearFilters() async {
        query = ExchangeQuery()
        await load()
    }

    /// An oblast tapped on the map (#417): on if it was off, off if it was on.
    func toggleRegion(_ code: String) async {
        query = query.togglingRegion(code)
        await load()
    }

    /// «Изчисти» on the region summary: the other filters stay.
    func clearRegions() async {
        guard !query.regions.isEmpty else { return }
        query.regions = []
        query.cursor = nil
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
