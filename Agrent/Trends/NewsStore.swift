import Foundation
import Observation

/// Which articles the feed asks for, and when a choice has gone stale
/// (#231). Pure, so the rules are tests rather than screens.
///
/// Owner, 2026-10-08: tags from the server's keyword rules, the choices kept
/// per person on the server, the feed showing only the chosen topics with a
/// «Всички» switch — nothing chosen means everything — and search on the
/// server. The contract is agri-saas's (#1446).
enum NewsTopics {
    enum Scope: Equatable, Sendable {
        /// «Моите теми»: the person's topics.
        case mine
        /// «Всички»: every article.
        case all
    }

    /// The tags to send: the chosen ones, in «Моите теми». None in
    /// «Всички», and none when nothing is chosen — nothing chosen means
    /// everything. Known ones only once the catalogue is in hand: the server
    /// ignores an unknown tag anyway, but a client that sends one makes
    /// every reply look stale. Sorted, as the server keys its cache.
    static func requested(chosen: [String]?, catalogue: NewsTagCatalogue?, scope: Scope) -> [String] {
        guard scope == .mine, let chosen, !chosen.isEmpty else { return [] }
        guard let catalogue else { return chosen.sorted() }
        let known = catalogue.keys
        return chosen.filter(known.contains).sorted()
    }

    /// The server dropped a tag it no longer knows: what it says it applied
    /// differs from what was sent. Nothing to compare against a server that
    /// predates the echo.
    static func isStale(sent: [String], echo: [String]?) -> Bool {
        guard let echo else { return false }
        return Set(echo) != Set(sent)
    }

    static func toggled(_ chosen: [String]?, _ key: String) -> [String] {
        var keys = Set(chosen ?? [])
        if keys.remove(key) == nil { keys.insert(key) }
        return keys.sorted()
    }

    /// An article's tags as the catalogue names them, in the catalogue's
    /// order; a key it does not know is left out rather than shown as code.
    static func labels(_ tags: [String]?, in catalogue: NewsTagCatalogue?) -> [NewsTagCatalogue.Tag] {
        guard let tags, !tags.isEmpty, let catalogue else { return [] }
        let wanted = Set(tags)
        return catalogue.groups.flatMap(\.tags).filter { wanted.contains($0.key) }
    }
}

/// Новини (#231): the feed, its search, the person's topics and the
/// catalogue that names them.
@Observable
@MainActor
final class NewsStore {
    private(set) var feed: LoadState<NewsResponse> = .loading
    private(set) var items: [NewsItem] = []
    private(set) var nextCursor: String?
    private(set) var loadingMore = false

    private(set) var catalogue: NewsTagCatalogue?
    /// Why the catalogue could not be read, while none is held — offline
    /// with nothing kept, say. «Предпочитания» says it and offers the read
    /// again, instead of a spinner for a list that is not coming.
    private(set) var catalogueError: String?
    /// The person's topics; nil until read, and when the read failed — the
    /// feed then shows everything, which is what nothing chosen means.
    private(set) var chosen: [String]?
    /// Whether the person's topics have been read. The switches wait for it:
    /// `chosen` is nil both for «never chose» and for a read that failed,
    /// and a flip after a failed read would save a list built from nothing
    /// over the topics the person keeps on the server.
    private(set) var preferencesRead = false
    /// Said in «Предпочитания» when the topics could not be read.
    private(set) var preferencesReadError: String?
    /// Said in «Предпочитания» when a choice did not reach the server.
    private(set) var preferencesError: String?

    /// The search field, bound.
    var query = ""
    /// What the feed on screen answers — the field can hold words that were
    /// never submitted.
    private(set) var appliedQuery: String?
    /// The tags the page on screen was asked with. Its cursor is theirs, so
    /// the next page is asked with them too, not with whatever is chosen now.
    @ObservationIgnored private var appliedTags: [String] = []
    private(set) var scope: NewsTopics.Scope = .mine

    /// The person's topics on the network, as two closures so the rules
    /// around them — nothing saved before they are read, one save at a
    /// time, the newest list last — are unit tests: there is no URLProtocol
    /// seam in `Tests/`. Defaulted to the real route; only tests pass
    /// anything else, and nothing in the suite sends the PUT.
    private let readTopics: () async throws -> [String]?
    private let sendTopics: ([String]) async throws -> [String]

    init(
        readTopics: @escaping () async throws -> [String]? = NewsPreferencesAPI.load,
        sendTopics: @escaping ([String]) async throws -> [String] = NewsPreferencesAPI.save
    ) {
        self.readTopics = readTopics
        self.sendTopics = sendTopics
    }

    var hasChoices: Bool { !(chosen ?? []).isEmpty }
    var requestedTags: [String] { NewsTopics.requested(chosen: chosen, catalogue: catalogue, scope: scope) }

    func isChosen(_ key: String) -> Bool { chosen?.contains(key) ?? false }

    /// The catalogue and the choices, then the feed they decide.
    func start() async {
        await loadCatalogue()
        await loadPreferences()
        await loadFeed()
    }

    func loadCatalogue() async {
        if catalogue == nil { catalogueError = nil }
        await CachedResource.loadShowingCacheFirst(TrendsAPI.newsTagsPath) { data in
            try await APIClient.shared.decode(data, as: NewsTagCatalogue.self)
        } publish: { [weak self] state in
            guard let self else { return }
            switch state {
            case .loaded(let value, _):
                self.catalogue = value
                self.catalogueError = nil
            case .failed(let message):
                // A catalogue already held stays; the failure is only news
                // when there is nothing to show — and a read cut short (the
                // sheet closed under it) is not a failure at all.
                if self.catalogue == nil, !Task.isCancelled { self.catalogueError = message }
            case .loading:
                break
            }
        }
    }

    /// Not cached: it is the person's, and a stale copy would filter the feed
    /// by choices they have since changed. A failed read keeps what is held.
    func loadPreferences() async {
        do {
            let tags = try await readTopics()
            // A flip made while this was on the wire is newer than it, and
            // its save will answer with the list the server now keeps.
            if !saveInFlight && !unsaved { chosen = tags }
            preferencesRead = true
            preferencesReadError = nil
        } catch {
            // Cut short — the sheet closed under it — is not a failure to say.
            guard !Task.isCancelled else { return }
            if !preferencesRead {
                preferencesReadError = NewsTopicsText.notRead(UserMessage.text(for: error))
            }
        }
    }

    /// Which `loadFeed` is the latest. A search, a scope chip, the sheet
    /// closing and a pull each start one, and their answers can land in any
    /// order; only the latest one's may reach the screen, or an older
    /// search's articles would sit under the newer one's words.
    @ObservationIgnored private var latestLoad = 0
    /// Counts the pages put on screen — twice for one load when the cached
    /// page shows first. A next page asked for before the count moved
    /// continues a list that is no longer there.
    @ObservationIgnored private var shownPages = 0

    /// The first page for the scope, the topics and the submitted search.
    func loadFeed() async {
        latestLoad += 1
        let load = latestLoad
        if feed.value == nil { feed = .loading }
        let tags = requestedTags
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = trimmed.isEmpty ? nil : trimmed
        let path = TrendsAPI.newsPath(tags: tags, query: search, cursor: nil)
        if search == nil {
            await CachedResource.loadShowingCacheFirst(path) { data in
                try await APIClient.shared.decode(data, as: NewsResponse.self)
            } publish: { [weak self] in self?.apply($0, load: load, tags: tags, query: nil) }
        } else {
            // A search is a question, not a page worth keeping offline: never
            // cached, as Борса's board keeps only its unfiltered page.
            let state: LoadState<NewsResponse>
            do {
                let data = try await APIClient.shared.data(for: path)
                state = .loaded(try await APIClient.shared.decode(data, as: NewsResponse.self), .fresh)
            } catch {
                state = .failed(UserMessage.text(for: error))
            }
            apply(state, load: load, tags: tags, query: search)
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let page = shownPages
        let path = TrendsAPI.newsPath(tags: appliedTags, query: appliedQuery, cursor: cursor)
        guard let data = try? await APIClient.shared.data(for: path),
              let next = try? await APIClient.shared.decode(data, as: NewsResponse.self),
              page == shownPages
        else { return }
        var seen = Set(items.map(\.id))
        items += next.items.filter { seen.insert($0.id).inserted }
        nextCursor = next.nextCursor
    }

    func setScope(_ new: NewsTopics.Scope) async {
        guard new != scope else { return }
        scope = new
        feed = .loading
        await loadFeed()
    }

    // MARK: - Choosing topics

    @ObservationIgnored private var saveInFlight = false
    @ObservationIgnored private var unsaved = false
    /// The save a flip started, while it runs — for the tests to await.
    @ObservationIgnored private(set) var saving: Task<Void, Never>?

    /// The switch moves at once; the whole list is written behind it. Saves
    /// are COALESCED — one in flight, then one more with the latest list —
    /// so quick flips cannot land out of order and leave an older list on
    /// the server. A save that fails keeps the person's choice on screen and
    /// says it was not saved; the next flip, or «Опитай пак» beside the
    /// message (`retrySave`), writes the whole list again.
    func toggle(_ key: String) {
        // The switches are disabled until the topics are read; the rule is
        // kept here too, where the save that would overwrite them is.
        guard preferencesRead else { return }
        chosen = NewsTopics.toggled(chosen, key)
        save()
    }

    /// The list on screen, written again after a save that failed.
    func retrySave() {
        guard preferencesRead else { return }
        save()
    }

    private func save() {
        unsaved = true
        guard !saveInFlight else { return }
        // Claimed before the task starts, so a second flip in the same turn
        // joins this save rather than starting its own beside it.
        saveInFlight = true
        saving = Task { await self.saveChoices() }
    }

    private func saveChoices() async {
        defer {
            saveInFlight = false
            saving = nil
        }
        while unsaved {
            unsaved = false
            let wanted = chosen ?? []
            do {
                let saved = try await sendTopics(wanted)
                if !unsaved { chosen = saved }
                preferencesError = nil
            } catch {
                preferencesError = NewsTopicsText.notSaved(UserMessage.text(for: error))
            }
        }
    }

    // MARK: - Applying a page

    @ObservationIgnored private var reconciling = false

    private func apply(_ state: LoadState<NewsResponse>, load: Int, tags sent: [String], query: String?) {
        guard load == latestLoad else { return }
        feed = state
        appliedTags = sent
        appliedQuery = query
        shownPages += 1
        switch state {
        case .loaded(let page, _):
            items = page.items
            nextCursor = page.nextCursor
            // The server dropped a tag it no longer knows (renamed, say):
            // re-read the catalogue and the choices, once, so what the screen
            // calls «Моите теми» is what the server applied.
            if NewsTopics.isStale(sent: sent, echo: page.tags), !reconciling {
                reconciling = true
                Task {
                    await self.loadCatalogue()
                    await self.loadPreferences()
                    self.reconciling = false
                }
            }
        case .failed, .loading:
            items = []
            nextCursor = nil
        }
    }
}

/// What Новини says that is not a label from the catalogue, in Bulgarian.
enum NewsTopicsText {
    static let searchPrompt = "Търсене в новините"
    static let mine = "Моите теми"
    static let all = "Всички"

    static func notSaved(_ reason: String) -> String {
        "Предпочитанията не са запазени. \(reason)"
    }

    static func notRead(_ reason: String) -> String {
        "Избраните теми не са прочетени. \(reason)"
    }

    /// The server keeps sixty days of news (`RETENTION_DAYS`, contract §6),
    /// so an empty search is that, not a failure.
    static func nothingFound(_ query: String) -> (title: String, message: String) {
        ("Няма новини за „\(query)“", "Търсенето обхваща новините от последните 60 дни.")
    }

    static let nothingForTopics = (
        title: "Няма новини по вашите теми",
        message: "Изберете „Всички“ или добавете теми в „Предпочитания“."
    )
}
