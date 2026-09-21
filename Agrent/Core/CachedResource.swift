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
