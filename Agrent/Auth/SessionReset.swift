import Foundation

/// A real sign-out — agri-saas#1191 P0.9, the LOCAL half.
///
/// The plan's test, and the only one that matters: account B signing in on
/// the same phone after A signs out sees NOTHING of account A. Before this,
/// Изход cleared the tokens and `CurrentUserStore` and nothing else, so B got
/// A's unread badge, A's bottom bar, A's dashboard, A's queued sprays (in the
/// banner, and SENT under B's session — a БАБХ record attributed to the wrong
/// person), and A's cached journal, members and farm profile whenever the
/// network was slower than the disk.
///
/// ── Local, synchronous, and never waits on the network ──
///
/// Everything here runs before `AuthClient` flips to `.signedOut`, with no
/// `await` in front of it. A sign-out that depends on a request completing is
/// a sign-out that does not happen in a field. The server-side revoke is a
/// separate, fire-and-forget seam (`SessionRevocation`) that runs AFTER.
///
/// ── What is reset, store by store ──
///
/// Every `static let` singleton in the app is accounted for here, and
/// `SignOutHygieneTests.testEverySingletonIsAccountedFor` fails the build's
/// tests when a new one is added without joining this list.
///
///   RESET to its initial state, in `resetUserState()`:
///     · `CurrentUserStore.shared`   — A's name, email, role.
///     · `BottomTabsStore.shared`    — A's server-synced bar order and the
///                                      operator flag derived from A's role.
///                                      Per USER (it is A's `/me`), not per
///                                      device, so it is user data.
///     · `ExchangeUnreadStore.shared`— which of A's farm's threads are unread.
///     · `OutboxStore.shared`        — its in-memory list and its pause. The
///                                      QUEUE ON DISK IS NOT TOUCHED; see below.
///                                      Nor is `isClientTooOld` (#168): it is
///                                      the server's word on this BUILD, which
///                                      the next person runs too.
///     · `RateLimitPause.messages`   — A's farm's message budget. B may be on
///                                      another farm, and a pause that is wrong
///                                      for B blocks B's sends for up to a
///                                      minute; a pause that is reset when it
///                                      was right for B costs exactly one 429,
///                                      which closes it again.
///     · `FeatureFlags.shared`       — the flags `/me` resolved for A's
///                                      cohort (agri-saas#1209). Never on disk,
///                                      so the reset is the whole of it; B's own
///                                      `/me` adopts B's.
///     · `DashboardPreferences.shared` — the Табло arrangement and the price
///                                      block's crop. Stored per DEVICE (there
///                                      is no server key), but it is a person's
///                                      choice, not a property of the phone,
///                                      and the crop A follows says something
///                                      about A's farm. Reset by default, per
///                                      the owner's rule; the cost is that two
///                                      people sharing a phone each re-arrange
///                                      after the other.
///     · `AccountAvatarStore.shared` — A's picture on the account card.
///                                      In memory only (#136), so the reset is
///                                      the whole of it; B's Админ asks for B's.
///     · `FarmStore.shared`          — which farm A had open (#179), and with
///                                      it `ActiveFarm.shared`, the mirror it
///                                      alone writes. B's sign-in settles B's
///                                      farm. A's CHOICE stays remembered on
///                                      the phone under A's id (`FarmMemory`),
///                                      for when A signs back in — it names a
///                                      farm A belongs to, never B's data.
///
///   PURGED, then made unreachable by key:
///     · `ResponseCache.shared`      — `removeAll()` here, and every entry is
///                                      keyed on `CacheScope` (user + farm), so
///                                      a purge that does not run still cannot
///                                      serve A's bytes to B.
///
///   PARKED, not dropped:
///     · `PendingOperations.shared`  — A's queued operations stay on disk,
///                                      stamped with A's id, invisible to and
///                                      never sent by B, and resume when A
///                                      signs back in. Each is the only copy of
///                                      a record of regulated work.
///
///   NOT user data, left alone:
///     · `APIClient.shared`          — a session and a decoder. Its one piece of
///                                      state, an in-flight refresh, is made safe
///                                      by `APIClient.mayCommitRefresh`: a
///                                      refresh that lands after Изход no longer
///                                      writes A's tokens back into the Keychain.
///     · `SessionIdentity.shared`    — cleared (it IS the session), by
///                                      `TokenStore.clear()` and again here.
///     · `@AppStorage("exchange.showMap")` and
///       `@AppStorage("locations.parcelMapMode")` — list-or-map and which map
///                                      renderer. How THIS SCREEN draws, chosen
///                                      for this phone's size and signal; they
///                                      name nothing of anybody's farm. Kept.
///
///   NOT singletons, and why they need nothing: every other store
///   (`AdminStore` — the members list and the farm's ЕГН/ЕИК/УРН —
///   `JournalStore`, `ExchangeInboxStore`, `ConversationStore`, …) is a
///   view's `@State`, and every view that owns one lives under `MainTabView`,
///   which `AgrentApp` tears down the moment `auth.state` leaves `.signedIn`.
///   Their requests in flight can only write to the store that is being
///   discarded — except where they write to a SINGLETON, which is what
///   `SessionEpoch` is for.
@MainActor
enum SessionReset {
    /// Clear the tokens, the identity, every per-user singleton, and the
    /// response cache. Returns the purge so a test can await it; the app
    /// does not, because nothing should wait on a file deletion.
    ///
    /// Parameters are seams for `SignOutHygieneTests`, which must not clear
    /// the Keychain or the response cache of whatever simulator it runs on.
    @discardableResult
    static func endSession(
        clearTokens: () -> Void = TokenStore.clear,
        identity: SessionIdentity = .shared,
        cache: ResponseCache? = .shared
    ) -> Task<Void, Never> {
        // FIRST: anything in flight that started under the old session is
        // now stale, and checks this before writing to a singleton.
        SessionEpoch.advance()
        clearTokens()
        identity.clear()
        resetUserState()
        return Task { await cache?.removeAll() }
    }

    /// The same, at the START of a sign-in, before the new tokens are saved.
    ///
    /// Because not every session ends with Изход. A refresh that is refused
    /// (401) clears the tokens and nothing else, and the app may be killed
    /// before anyone taps anything; the next person to sign in would then
    /// inherit whatever the last one left. A sign-in that starts from nothing
    /// does not depend on the previous session having ended cleanly.
    @discardableResult
    static func beginFreshSession(
        clearTokens: () -> Void = TokenStore.clear,
        identity: SessionIdentity = .shared,
        cache: ResponseCache? = .shared
    ) -> Task<Void, Never> {
        endSession(clearTokens: clearTokens, identity: identity, cache: cache)
    }

    /// Every user-data singleton back to how a fresh launch finds it.
    ///
    /// THE LIST. A new `static let shared` that holds anything of a user's
    /// joins it, or `SignOutHygieneTests` fails — see the header for each
    /// entry's reason.
    static func resetUserState() {
        CurrentUserStore.shared.clear()
        BottomTabsStore.shared.reset()
        ExchangeUnreadStore.shared.reset()
        OutboxStore.shared.reset()
        RateLimitPause.messages.reset()
        DashboardPreferences.shared.reset()
        FeatureFlags.shared.reset()
        AccountAvatarStore.shared.reset()
        FarmStore.shared.reset()
    }
}

/// Which session a piece of in-flight work belongs to.
///
/// A request that started under A and answers after Изход must not write A's
/// answer into a singleton B is about to read: `/me` resolving into
/// `CurrentUserStore`, the inbox's first page into the unread badge, a failed
/// bar save rolling `BottomTabsStore` back to A's order. Each captures the
/// epoch before its `await` and drops its result if the epoch has moved.
///
/// A counter rather than a check of WHO is signed in, because "A signed out
/// and A signed back in" is also a new session: the badge A had before is not
/// A's badge now.
@MainActor
enum SessionEpoch {
    private(set) static var current = 0

    static func advance() { current &+= 1 }

    static func isCurrent(_ epoch: Int) -> Bool { epoch == current }
}

/// Server-side revocation: end THIS DEVICE's session on agri-saas
/// (agri-saas#1191 P0.9, the server half; the route is agri-saas#1206).
///
/// ── Best-effort, fire-and-forget, AFTER the local clear ──
///
/// By the time this runs `SessionReset.endSession()` has already removed the
/// tokens, the identity and every per-user singleton. Nothing here can undo
/// or delay that: it is a detached task, never awaited, and its answer is
/// only logged. ONE attempt, no retry loop. Offline, the request fails and
/// the refresh token dies with the Keychain item it was in — nothing on this
/// phone can present it again, and the server expires it on its own
/// schedule. A retry would be SAFE (the route answers 200 even for an unknown
/// token, RFC 7009, so a second attempt cannot error for work the first
/// already did), but a retry queue that outlives the sign-out would be the
/// one piece of A's credential still on the phone after A left, which is
/// exactly what sign-out exists to prevent.
///
/// ── What it revokes: the session the credential DESCENDS FROM ──
///
/// The server ends the session the refresh token hangs from, plus every token
/// on it — not the account; the person's other phones stay signed in, per the
/// owner's "only this phone" decision. The caveat #1206 states, kept here so
/// nobody has to discover it: a native credential is a CHILD of the session
/// the browser sign-in created. `AuthClient.present` sets
/// `prefersEphemeralWebBrowserSession = false`, so that browser is Safari's
/// shared cookie jar; if the person was already signed in to app.agrent.bg in
/// Safari on this phone, the native session descends from THAT login and this
/// ends it too. The blast radius is the session the credential descends from,
/// which usually coincides with the device and is not guaranteed to. A web
/// login on the SAME phone is within "only this phone", so it is accepted
/// rather than engineered around.
///
/// ── Unauthenticated, by the route's construction ──
///
/// The refresh token IS the credential (`security: NO_AUTH` in the spec, the
/// pre-auth rate-limit tier, like `/token/refresh`), so no `Authorization`
/// header is sent — and there is none to send: the access token was cleared
/// with the rest. On `NoURLCache.session` rather than `APIClient` for the
/// same reason: no bearer, no refresh-on-401, no fixture seam, nothing in
/// Cache.db.
///
/// ── NOT `/api/auth/logout` ──
///
/// That route clears a web cookie. The native session is a bearer pair with
/// no cookie, so calling it would succeed and revoke nothing — a sign-out
/// that LOOKS server-side and is not. A source guard in
/// `SignOutHygieneTests` keeps it out of the sign-out path.
///
/// ── Until agri-saas#1206 deploys ──
///
/// The route is merged (in the route snapshot from agri-saas main a3df5f0,
/// documented). On a server that predates it, the request falls through to
/// NextAuth's `/api/auth/[...nextauth]` catch-all and is refused, and that
/// answer is ignored like any other: the outcome is the old one (the token
/// dies with the Keychain item).
enum SessionRevocation {
    /// `POST`, body `{ "refreshToken": "…" }` — the field name in both the
    /// route (`'refreshToken' in body`) and its `NativeRevokeRequest` schema.
    static let path = "/api/auth/native/revoke"

    /// The request as a pure value, so its path, method, headers and body are
    /// testable with no network. No `Authorization`; see above.
    static func request(refreshToken: String, baseURL: URL = Config.baseURL) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        ClientHeader.stamp(&req)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A one-key String dictionary cannot fail to encode; `try?` keeps the
        // builder non-throwing for a caller that must not branch on it.
        req.httpBody = try? JSONEncoder().encode(["refreshToken": refreshToken])
        // Short: nobody waits on it, but a detached request hanging for the
        // session default (60s) keeps the token in memory that much longer.
        req.timeoutInterval = 15
        return req
    }

    /// Fire once and return at once. `send` is the seam for tests, which
    /// must never reach a real server; the app passes nothing.
    ///
    /// `refreshToken` is read by the caller BEFORE the local clear — after
    /// it, the Keychain has nothing left to read.
    @discardableResult
    static func revokeThisDevice(
        refreshToken: String?,
        send: @escaping @Sendable (URLRequest) async throws -> Int = SessionRevocation.sendOnce
    ) -> Task<Void, Never>? {
        // Nothing to present (a refused refresh already cleared it), or an
        // empty string the route would answer 400 to: no request at all.
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        let req = request(refreshToken: refreshToken)
        return Task.detached(priority: .utility) {
            do {
                let status = try await send(req)
                // The status and nothing else: a 200 says nothing about
                // whether a token matched (RFC 7009), and no token material
                // is ever logged.
                Log.auth.info("native revoke → \(status, privacy: .public)")
            } catch {
                Log.auth.info("native revoke not sent: \(Log.summary(for: error), privacy: .public)")
            }
        }
    }

    /// The real send: one request on the cache-less session, status out.
    @Sendable
    static func sendOnce(_ req: URLRequest) async throws -> Int {
        let (_, response) = try await NoURLCache.session.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}
