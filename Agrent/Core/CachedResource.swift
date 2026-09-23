import Foundation

/// Network first, cache as the fallback — the one loading policy every read
/// screen in the app uses.
///
/// The ORDER is the design. Cache-first would render instantly and then flicker
/// when the network answered, and worse, it would show stale data even when
/// fresh data was one round trip away. Network-first costs a spinner on a good
/// connection and pays for it on a bad one, which is the trade a phone in a
/// field wants.
///
/// The decode step is a closure rather than a generic `Decodable` bound
/// because at least one endpoint answers in two shapes — see
/// `JournalAPI.decodeList(from:)`. Handing the closure both the fresh and the
/// cached bytes means cached data goes through exactly the same defensive
/// decode as fresh data, instead of a simpler one that happens to work today.
enum CachedResource {
    /// Cached copy first, network behind it.
    ///
    /// ── Why this reverses the policy above ──
    ///
    /// The header argues network-first is "the trade a phone in a field
    /// wants". A real phone in airplane mode disproved it. Airplane mode
    /// on iOS commonly leaves Wi-Fi ON, so the device holds a link to a
    /// router and believes it has connectivity — there is no fast failure
    /// to fall back from, and every screen waited out the request timeout
    /// before consulting a cache that was populated and correct the whole
    /// time.
    ///
    /// Shortening the timeout only shortens the wait. The wait itself is
    /// the defect: an app that already has the answer should not make
    /// somebody watch a spinner to be told it.
    ///
    /// So: publish the cache the instant it is read, then publish the
    /// network result when it arrives. On a good connection the second
    /// publish lands in well under a second and the first is invisible. On
    /// no connection the first is the whole answer.
    ///
    /// The staleness is not hidden — every screen that uses this carries
    /// `StaleBanner`, and the first publish is marked `.stale` with the
    /// time it was fetched. The reader is told what they are looking at.
    ///
    /// The network result is published even when it FAILS, so a genuine
    /// error still reaches the screen — but only after the cached data has
    /// already been shown, so the failure never costs the reader the
    /// content.
    /// - Parameter showCachedFirst: pass `false` for an EXPLICIT refresh — a
    ///   pull-to-refresh already has content on screen, and re-publishing
    ///   the cached copy under the reader's finger re-renders the list
    ///   mid-gesture for no gain. They asked for fresh; give them fresh or
    ///   an error.
    static func loadShowingCacheFirst<T: Equatable & Sendable>(
        _ pathAndQuery: String,
        showCachedFirst: Bool = true,
        decode: @Sendable (Data) async throws -> T,
        publish: @MainActor @Sendable (LoadState<T>) -> Void
    ) async {
        let key = ResponseCache.key(tenant: Config.tenantSlug, pathAndQuery: pathAndQuery)
        let hit = await ResponseCache.shared.read(key)
        if let hit, showCachedFirst {
            if let value = try? await decode(hit.data) {
                await publish(.loaded(value, .stale(since: hit.fetchedAt)))
            } else {
            }
        }
        let fresh = await load(pathAndQuery, decode: decode)
        // A network failure must not replace content already on screen
        // with an error. The cache already answered; the failure is only
        // news if there was nothing to show.
        if case .failed = fresh {
            if await ResponseCache.shared.read(key) == nil { await publish(fresh) }
        } else {
            await publish(fresh)
        }
    }

    static func load<T: Equatable & Sendable>(
        _ pathAndQuery: String,
        decode: @Sendable (Data) async throws -> T
    ) async -> LoadState<T> {
        let key = ResponseCache.key(tenant: Config.tenantSlug, pathAndQuery: pathAndQuery)

        do {
            let data = try await APIClient.shared.data(for: pathAndQuery)
            // Decode BEFORE writing. A payload we cannot read must never
            // become the thing we later fall back to.
            let value = try await decode(data)
            await ResponseCache.shared.write(key, data)
            return .loaded(value, .fresh)
        } catch APIClient.APIError.notModified {
            // Not a failure — the server just told us the cached copy is
            // current. So the cache is served as .fresh, NOT .stale: the age
            // shown to an operator should reflect how current the DATA is,
            // and the server has this second confirmed it is.
            if let hit = await ResponseCache.shared.read(key),
               let value = try? await decode(hit.data) {
                return .loaded(value, .fresh)
            }
            // A 304 with nothing cached to pair it with — the app asked to
            // revalidate something it does not hold. Nothing to show.
            return .failed(UserMessage.text(for: APIClient.APIError.notModified))
        } catch {
            return await fallback(key: key, error: error, decode: decode)
        }
    }

    private static func fallback<T: Equatable & Sendable>(
        key: String,
        error: Error,
        decode: @Sendable (Data) async throws -> T
    ) async -> LoadState<T> {
        guard let hit = await ResponseCache.shared.read(key) else {
            return .failed(UserMessage.text(for: error))
        }
        do {
            let value = try await decode(hit.data)
            return .loaded(value, .stale(since: hit.fetchedAt))
        } catch {
            // Corrupt bytes, a truncated write, or a payload written by an
            // older build whose shape no longer decodes. Discard the entry
            // rather than letting one bad file wedge the screen forever —
            // the next successful fetch repopulates it.
            Log.cache.error("cached payload did not decode, evicting")
            await ResponseCache.shared.remove(key)
            return .failed(UserMessage.text(for: error))
        }
    }
}
