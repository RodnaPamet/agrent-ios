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
///     · `RateLimitPause.messages`   — A's farm's message budget. B may be on
///                                      another farm, and a pause that is wrong
///                                      for B blocks B's sends for up to a
///                                      minute; a pause that is reset when it
///                                      was right for B costs exactly one 429,
///                                      which closes it again.
///     · `DashboardPreferences.shared` — the Табло arrangement and the price
///                                      block's crop. Stored per DEVICE (there
///                                      is no server key), but it is a person's
///                                      choice, not a property of the phone,
///                                      and the crop A follows says something
///                                      about A's farm. Reset by default, per
///                                      the owner's rule; the cost is that two
///                                      people sharing a phone each re-arrange
///                                      after the other.
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

/// Server-side revocation — THE SEAM, not the call.
///
/// ── TODO(agri-saas#1191 P0.9): `POST /api/auth/native/revoke` ──
///
/// The endpoint does NOT exist yet; Agri-SaaS backend 2 is building it. The
/// owner's decision fixes its scope: it revokes ONLY this device's session —
/// the refresh token's session family — not the user's other devices. When
/// it lands, this sends `{ "refreshToken": … }` on `NoURLCache.session`, in a
/// detached task, and ignores the answer: by the time it runs the tokens are
/// already gone from this phone, and a failure here must never be able to
/// undo or delay that.
///
/// ── NOT `/api/auth/logout` ──
///
/// That route clears a web cookie. The native session is a bearer pair with
/// no cookie, so calling it would succeed and revoke nothing — a sign-out
/// that LOOKS server-side and is not. A source guard in
/// `SignOutHygieneTests` keeps it out of the sign-out path.
///
/// Until the endpoint exists the refresh token simply dies with the
/// Keychain item: nothing on this phone can present it again, and the server
/// expires it on its own schedule.
enum SessionRevocation {
    static func revokeThisDevice(refreshToken: String?) {
        // TODO(agri-saas#1191 P0.9): POST /api/auth/native/revoke — not yet built.
        // Intentionally does nothing today.
        _ = refreshToken
    }
}
