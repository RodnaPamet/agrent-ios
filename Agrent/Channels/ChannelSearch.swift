import Foundation
import Observation

/// «Канали»'s search (P9.7, #614; agri-saas #3072): the words, the scope,
/// and the hits, newest first.
///
/// Searched on SUBMIT, as Борса's board and Новини are: a round trip per
/// keystroke on a field connection, and a line in the unified log for each,
/// otherwise. Changing the scope searches the submitted words again. An
/// answer to words or a scope that has since changed is dropped, so the list
/// never shows hits for something no longer asked. Read-only.
@MainActor
@Observable
final class ChannelSearch {
    /// The field.
    var needle = ""
    private(set) var scope: ChannelsAPI.SearchScope = .joined
    /// What was last submitted, trimmed; nil when nothing is.
    private(set) var submitted: String?
    private(set) var hits: [ChannelsAPI.SearchHit] = []
    /// The scope the server applied to `hits`.
    private(set) var applied: ChannelsAPI.SearchScope?
    private(set) var hasMore = false
    private(set) var searching = false
    private(set) var failure: String?

    private var generation = 0
    private let fetch: @MainActor (String, ChannelsAPI.SearchScope, Date?, String?) async throws -> ChannelsAPI.SearchPage

    init(fetch: @escaping @MainActor (String, ChannelsAPI.SearchScope, Date?, String?) async throws
            -> ChannelsAPI.SearchPage = { try await ChannelsAPI.search($0, scope: $1, before: $2, beforeID: $3) }) {
        self.fetch = fetch
    }

    /// Results replace the channels while something is submitted.
    var isActive: Bool { submitted != nil }
    /// Under two characters the server answers 400, so nothing is sent.
    var tooShort: Bool { (submitted?.count ?? 0) < ChannelsAPI.searchMinimum && isActive }

    /// Return in the field, or the field cleared.
    func submit() async {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = trimmed.isEmpty ? nil : trimmed
        await run()
    }

    func choose(_ scope: ChannelsAPI.SearchScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        await run()
    }

    private func run() async {
        generation += 1
        let mine = generation
        hits = []
        applied = nil
        hasMore = false
        failure = nil
        guard let words = submitted, !tooShort else {
            searching = false
            return
        }
        searching = true
        do {
            let page = try await fetch(words, scope, nil, nil)
            guard mine == generation else { return }
            hits = page.hits
            applied = page.scope
            hasMore = page.hasMore
        } catch {
            guard mine == generation else { return }
            failure = UserMessage.text(for: error)
        }
        searching = false
    }

    /// The next page, on the oldest hit's instant and id.
    func loadMore() async {
        guard hasMore, !searching, let words = submitted, let oldest = hits.last?.post else { return }
        let mine = generation, scope = scope
        searching = true
        defer { if mine == generation { searching = false } }
        do {
            let page = try await fetch(words, scope, oldest.createdAt, oldest.id)
            guard mine == generation else { return }
            var seen = Set(hits.map(\.id))
            hits += page.hits.filter { seen.insert($0.id).inserted }
            hasMore = page.hasMore
        } catch {
            guard mine == generation else { return }
            failure = UserMessage.text(for: error)
        }
    }
}
