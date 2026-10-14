import Foundation

/// This phone's APNs registration with each farm (agrent-ios#272; agri-saas
/// #1764, route live since #1789).
///
/// ── One route, two transports ──
///
/// `POST /api/t/{slug}/push-subscriptions` took a browser's W3C subscription
/// and nothing else until #1789. It now also takes `{platform: "IOS",
/// deviceToken}`, answers `201 {id}`, and is idempotent on (farm, person,
/// token) — which is what lets the phone send it on every launch, as iOS
/// hands the app its token on every launch. `DELETE` takes the same body.
/// The route is on agri-saas's undocumented baseline; the shapes are read
/// from `push.schemas.ts` (`ApnsRegistrationSchema`,
/// `RemoveApnsRegistrationSchema`).
///
/// ── Per FARM ──
///
/// A token is stored under the farm in the path, and the server sends a
/// farm's task assignments and weather alerts to the devices registered IN
/// THAT FARM. So a person with two farms registers twice, or hears from one.
///
/// ── Stored, not yet sent to ──
///
/// The server accepts a token before it can deliver to it: the APNs
/// transport is #1764's step 3 and waits on the owner's APNs key. Asking the
/// person for permission waits for that too (owner, 2026-10-14) — a token
/// needs no permission, an alert does.
enum PushAPI {
    static func subscriptionsPath(in farm: String) -> String {
        FarmPath.root(for: farm) + "/push-subscriptions"
    }

    /// The body of both the registration and its removal.
    ///
    /// No APNs environment yet: a development-signed install's token is a
    /// SANDBOX token and a TestFlight or App Store one is a production token,
    /// and the server cannot tell them apart. Asked of backend 1 on
    /// 2026-10-14; the field joins this body once it is in the server's schema.
    struct Registration: Encodable, Equatable, Sendable {
        let platform: String
        /// 64 lowercase hex characters — the server's pin is
        /// `^[0-9a-f]{64}$`, case-insensitive.
        let deviceToken: String

        init(deviceToken: String) {
            self.platform = "IOS"
            self.deviceToken = deviceToken
        }
    }

    /// The token as the server pins it: two lowercase hex digits per byte.
    /// `Data.description` is not that, and never was a format to rely on.
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Register this phone with `farm`. The answer's id is not kept: the
    /// token itself addresses the row, for the removal as for a repeat.
    static func register(_ deviceToken: String, in farm: String) async throws {
        _ = try await APIClient.shared.postReturningData(
            subscriptionsPath(in: farm),
            body: Registration(deviceToken: deviceToken),
            // Idempotent on the token server-side, so a key would read as
            // protection that is not there.
            idempotencyKey: nil
        )
    }

    /// The removal as a pure value, so its method, bearer and body are
    /// testable with no network.
    ///
    /// BUILT HERE WITH ITS OWN BEARER rather than sent through `APIClient`:
    /// it is sent at Изход, after `SessionReset` has cleared the Keychain
    /// that `APIClient` reads its token from. The access token is read by
    /// `AuthClient.signOut` before that clear and carried in.
    static func removalRequest(
        _ deviceToken: String, from farm: String, accessToken: String
    ) throws -> URLRequest {
        var req = try APIClient.request(
            for: subscriptionsPath(in: farm), method: "DELETE", accessToken: accessToken
        )
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Registration(deviceToken: deviceToken))
        // Short, as the revoke's: nobody waits on it, and the revoke waits
        // on IT — see `SessionRevocation.revokeThisDevice`.
        req.timeoutInterval = 10
        return req
    }
}

/// What Изход sends so this phone stops receiving a person's notifications:
/// one `DELETE` per farm the token was registered with, all at once.
///
/// Captured BEFORE the local clear — the token, the farms and the bearer all
/// go with it — and sent after, by `SessionRevocation.revokeThisDevice`,
/// AHEAD of the revoke: a revoked session's access token is refused at once
/// (agri-saas `bearer-principal.ts`), so the other order would answer every
/// removal 401.
///
/// Best-effort and one attempt, like the revoke. A removal that fails offline
/// leaves the person's rows on the server, and this phone keeps receiving
/// their farm's notifications until something removes them — the same
/// residual a failed revoke leaves, stated rather than discovered.
struct PushFarewell: Equatable, Sendable {
    let deviceToken: String
    let farms: [String]
    let accessToken: String

    func send(using send: @escaping @Sendable (URLRequest) async throws -> Int) async {
        await withTaskGroup(of: Void.self) { group in
            for farm in farms {
                guard let req = try? PushAPI.removalRequest(deviceToken, from: farm, accessToken: accessToken)
                else { continue }
                group.addTask {
                    do {
                        let status = try await send(req)
                        Log.auth.info("push unregister → \(status, privacy: .public)")
                    } catch {
                        Log.auth.info("push unregister not sent: \(Log.summary(for: error), privacy: .public)")
                    }
                }
            }
        }
    }
}
