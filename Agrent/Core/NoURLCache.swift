import Foundation
import MapKit

/// URLSession's HTTP cache is OFF, app-wide. `ResponseCache` is the only
/// thing in this app that writes a response to disk (#134).
///
/// ── Why ──
///
/// `URLSessionConfiguration.default` carries `URLCache.shared`, which is
/// DISK-backed: `Library/Caches/bg.agrent.app/Cache.db`, a SQLite file plus
/// `fsCachedData/`. Under Apple's rules any 2xx GET without
/// `Cache-Control: no-store` may be stored there, and agri-saas does not send
/// `no-store` (an unauthenticated probe carries no `Cache-Control` at all).
/// So everything the app was careful to keep OUT of `ResponseCache` — the
/// staff directory and the farm's ЕГН/ЕИК/УРН (`AdminStore`), other farms'
/// messages (PARITY Gap 7, "nothing is cached on disk") — could land in
/// Cache.db anyway, with the default file protection, surviving sign-out.
/// Every decision about what to persist was being made twice, and the second
/// maker was not reading the first one's notes.
///
/// ── Why app-wide rather than per endpoint ──
///
/// The owner's call (2026-10-01): one rule nobody has to remember beats a
/// list of sensitive paths that the next feature forgets to join. The cost is
/// bandwidth: URLSession no longer revalidates with `If-None-Match`, so an
/// ETagged route (farm-risk readings, parcel history) answers a full 200
/// instead of a 304. Those payloads are kilobytes; the offline story never
/// depended on Cache.db, it depends on `ResponseCache`.
///
/// ── The three doors, all closed here ──
///
///  1. `configuration()` — every session the app builds starts from it
///     (`APIClient`, `AuthClient.exchange`, tile loading).
///  2. `install()` — the PROCESS-WIDE `URLCache.shared`, replaced by a
///     zero-capacity cache at launch, after purging what older builds wrote.
///     That covers anything that reaches the shared cache without asking us:
///     `URLSession.shared`, and whatever MapKit's default tile loader uses.
///  3. `TileOverlay` — index tiles load through our own session rather than
///     MapKit's loader, so that guarantee does not rest on MapKit's internals.
///
/// `NoURLCacheTests` holds all three, with positive controls.
enum NoURLCache {
    /// `.default` (not `.ephemeral`) with the cache removed.
    ///
    /// `.ephemeral` would ALSO drop persistent cookies and credential storage,
    /// which is a separate change with its own blast radius — the API is
    /// bearer-token, but nobody has audited what cookies agri-saas sets. This
    /// does exactly what #134 asks and nothing else.
    ///
    /// The policy is belt and braces: with `urlCache == nil` there is nothing
    /// to read from, and `.reloadIgnoringLocalCacheData` says so explicitly in
    /// case someone hands the configuration a cache later.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// For the callers that do not need `APIClient`'s timeout and fixture
    /// seam: the token exchange and the index tiles.
    static let session = URLSession(configuration: configuration())

    /// For a THIRD-PARTY host: the account card's provider photo (an
    /// absolute `avatarUrl`, e.g. a Google profile picture). Nothing else.
    ///
    /// Not `session` above, and not `APIClient`'s: those carry this app's
    /// credentials one way or another — `APIClient` attaches the bearer to
    /// every request, and `session` shares the process's cookie and
    /// credential stores with the token exchange. A request to someone
    /// else's CDN must carry none of it, so this configuration has NO cookie
    /// store, sets no cookies and has no credential store, on top of having
    /// no URL cache. The caller still stamps `ClientHeader` (the house rule
    /// is every request) and never sets `Authorization`.
    ///
    /// Fifteen seconds and no waiting for connectivity, for `APIClient`'s
    /// reasons: a picture that cannot load should fall back to initials, not
    /// hold a request open for a minute.
    static func thirdPartyConfiguration() -> URLSessionConfiguration {
        let configuration = configuration()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return configuration
    }

    static let thirdPartySession = URLSession(configuration: thirdPartyConfiguration())

    /// Purge, then disable, the shared cache. Call once, before any request.
    ///
    /// PURGE FIRST: a build from before #134 has already written whatever it
    /// wrote, and replacing `URLCache.shared` only stops new writes — the old
    /// object's file stays on disk. `removeAllCachedResponses` on the ORIGINAL
    /// instance is what empties Cache.db.
    ///
    /// Zero capacity, not just `diskCapacity: 0`: an in-memory copy of a
    /// staff directory is not the leak #134 is about, but there is no reader
    /// that wants it either, and "no URL cache" is easier to verify than
    /// "a URL cache that is only in memory".
    static func install() {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
    }

    /// `MKTileOverlay` with the load routed through `NoURLCache.session`.
    ///
    /// The tiles are Earth Engine vegetation-index imagery — not personal
    /// data. But Earth Engine CLIPS each tile to the parcel outline, so a
    /// cached tile set is a picture of the farm's field boundaries, and the
    /// owner's rule is "no response of any kind". MapKit documents neither
    /// which session nor which cache its default `loadTile` uses, so rather
    /// than trust `install()` to have caught it, we do the load ourselves.
    ///
    /// Apple's own base imagery is NOT affected and is out of scope: MapKit
    /// fetches it out of process (geod) into its own cache, and it is Apple's
    /// public satellite imagery, not anything of this farm's.
    final class TileOverlay: MKTileOverlay {
        override func loadTile(
            at path: MKTileOverlayPath,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let request = URLRequest(
                url: url(forTilePath: path),
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            NoURLCache.session.dataTask(with: request) { data, response, error in
                // A non-2xx body is an error envelope, not a PNG. Handing it
                // to the renderer draws nothing either way; handing it back
                // as an error at least says why.
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    result(nil, URLError(.badServerResponse))
                } else {
                    result(data, error)
                }
            }.resume()
        }
    }
}
