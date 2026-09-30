#if DEBUG
import Foundation

/// EVERY REQUEST THROUGH `URLSession` ANSWERED FROM DISK.
///
/// Which is not the same as "nothing leaves the simulator", and the
/// difference is visible on one screen: `ParcelMapView`'s satellite modes are
/// MapKit, and MapKit fetches its tiles through its own stack rather than
/// through the `URLSessionConfiguration` this is installed on. A seam run
/// still pulls Apple's imagery. Nothing of the FARM's leaves — no tenant
/// data, no token, no geometry — but the claim is about this app's API
/// traffic, not about the process.
///
/// Installed at the FRONT of `URLSessionConfiguration.protocolClasses` by
/// `APIClient`, and only when `UITestSeam.isActive` — see the note there for
/// why a stub token on its own would not have been enough.
///
/// ── Why a `URLProtocol` and not a stubbed client ──
///
/// The alternative is an `APIClient` protocol with a fixture implementation,
/// which means every call site in the app resolving its client through some
/// injection point. `APIClient.shared` is reached directly from roughly
/// thirty places. A `URLProtocol` needs one line in one file and changes no
/// production code path: the real client, the real headers, the real
/// decoders, the real caching and the real error handling all run. What is
/// replaced is the socket.
///
/// That is also what makes the screenshots worth taking. A stubbed client
/// would photograph the fixture; this photographs the app's own decode of
/// the fixture, which is the thing that breaks.
///
/// ── A request with no fixture gets 501, not a plausible 200 ──
///
/// The catalogue covers the reads the screenshot harness walks and nothing
/// more. Everything else — task detail, parcel history, the agro tile routes,
/// the insurance catalogue — has no payload in this repo. So an uncovered
/// route is answered `501 NO_FIXTURE`, the screen shows its ordinary
/// server-error state, and the log names the path. A seam whose gaps are
/// invisible is a seam that reports coverage it does not have.
///
/// Табло, Новини, Риск and Админ were in that list until agrent-ios#115 moved
/// A11yShots onto this seam; they now have SYNTHETIC payloads, invented for
/// the purpose and labelled so in `Tests/Fixtures/README.md`. A screenshot of
/// them is a render of made-up data, and the harness's #97 comment says so
/// rather than letting it pass for the live tenant.
///
/// ── Writes are refused, and that is not caution ──
///
/// `ExchangeAPI.createInquiry` posts a row AND emails the seller tenant's
/// admins; `createListing` publishes to every tenant on the platform; and
/// every messaging write — open a thread, send, mark read, close, block,
/// unblock, retract — is seen by another farm (#114). Those ship built and
/// unfired by a standing decision recorded on the functions themselves. The
/// conversation screen marks read on OPENING, so here it meets a 501 on
/// every visit — and swallows it, which is what keeps it usable under the
/// seam. Nothing reaches the network here in any case — the protocol
/// answers before URLSession opens a socket — but a write is answered `501
/// WRITE_REFUSED` rather than a cheerful 200, because a UI test that appears
/// to save something is a UI test that will eventually be pointed at a
/// simulator whose seam was off.
final class FixtureURLProtocol: URLProtocol {
    /// The bundle the fixtures were copied into.
    ///
    /// `Bundle.main`, because `Tests/Fixtures` is a resource of the app
    /// target in the Debug configuration only (`project.yml`). In Release
    /// neither this file nor those files are in the build at all, which the
    /// CI step "The UI test seam cannot reach Release" checks against the
    /// produced binary rather than against the `#if`.
    static var bundle: Bundle { .main }

    /// Guarded a second time.
    ///
    /// `APIClient` only ever puts this class in `protocolClasses` when the
    /// seam is active, so this can only be false if somebody registers it
    /// elsewhere later. It costs one array scan per request and removes the
    /// class of mistake where a helpful line in a preview or a test quietly
    /// redirects the whole app's networking.
    override class func canInit(with request: URLRequest) -> Bool {
        UITestSeam.isActive
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            finish(status: 500, body: Self.envelope("NO_URL", "request carried no URL"))
            return
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let loggable = LoggablePath(path)

        guard method == "GET" else {
            Log.api.error(
                "fixture seam refused \(method, privacy: .public) \(loggable.value, privacy: .public)"
            )
            finish(status: 501, body: Self.envelope(
                "WRITE_REFUSED",
                "the UI test seam serves reads only; \(method) \(path) was not sent"
            ))
            return
        }

        guard let name = FixtureCatalogue.fixtureName(path: path, query: url.query) else {
            Log.api.error(
                "fixture seam has no payload for \(loggable.value, privacy: .public)"
            )
            finish(status: 501, body: Self.envelope(
                "NO_FIXTURE",
                "no recorded payload for \(path) — see FixtureCatalogue"
            ))
            return
        }

        guard let file = Self.bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: file)
        else {
            // The catalogue named a file the bundle does not hold. That is a
            // build problem, not a routing one, and saying which is the whole
            // difference between a five-minute fix and an afternoon.
            Log.api.error(
                "fixture seam: \(name, privacy: .public).json is in the catalogue but not in the bundle"
            )
            finish(status: 500, body: Self.envelope(
                "FIXTURE_MISSING",
                "\(name).json is not in the app bundle"
            ))
            return
        }

        Log.api.info(
            "fixture seam served \(loggable.value, privacy: .public) from \(name, privacy: .public).json (\(data.count, privacy: .public) bytes)"
        )
        finish(status: 200, body: data)
    }

    /// Nothing to cancel: every answer is produced synchronously inside
    /// `startLoading`, so by the time a caller could cancel there is no work
    /// left to stop.
    override func stopLoading() {}

    // MARK: - internals

    private func finish(status: Int, body: Data) {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        // `.notAllowed`, so URLSession's own HTTP cache never stores a
        // fixture and never answers a later request from one. The app's
        // `ResponseCache` is a separate thing and DOES store these — see the
        // warning in `UITestSeam`.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The server's own refusal shape, so a refusal from here is taken apart
    /// by `APIClient.envelope(from:)` exactly like a real one and reaches the
    /// screen as a sentence rather than as raw bytes.
    static func envelope(_ code: String, _ message: String) -> Data {
        let body = ["error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }
}
#endif
