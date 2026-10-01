import Foundation

/// WHOSE session this is — the user id the tokens belong to, as a value the
/// rest of the app can key on without a round trip (agri-saas#1191 P0.9).
///
/// ── Why it exists ──
///
/// Every per-user thing on disk needs an owner it can be checked against:
/// `ResponseCache` entries (so A's journal can never be served to B, even if
/// a purge fails) and queued field operations (so A's spray is never sent
/// under B's session). The tokens cannot answer: the access token is a
/// next-auth `encode()` — a JWE, ENCRYPTED, not a signed JWT — so there is no
/// readable `sub` claim on this side, and parsing one would be guessing at a
/// format the server is free to change. `GET /api/auth/me` is the one
/// authority, and this is where its `user.id` is remembered.
///
/// ── Lives and dies with the tokens ──
///
/// Stored in the Keychain beside them (`TokenStore`), and `TokenStore.clear()`
/// clears it. An identity that outlived its tokens is the dangerous half: the
/// next person's session would read and write under the previous person's
/// key until their own `/me` resolved. A sign-in clears it before saving the
/// new pair, for the same reason (see `SessionReset.beginFreshSession`).
///
/// ── Unknown is a real state, and it fails CLOSED ──
///
/// Between a sign-in and the first `/me`, and on the first launch of a build
/// from before this one, there is no identity. `CacheScope.current()` is then
/// nil, which turns the response cache off (no read, no write) rather than
/// guessing, and the outbox shows and sends nothing until an owner is known.
/// The cost is one launch's worth of offline cache after the upgrade; the
/// alternative was serving whatever was on disk to whoever held the token.
///
/// ── A class with a lock, not an actor ──
///
/// `CachedResource` and `APIClient` read it from nonisolated contexts, and the
/// outbox re-checks it per item. An `await` on every one of those reads would
/// be a suspension point in the middle of a decision that must be atomic with
/// the work it guards; a lock-protected mirror answers synchronously.
final class SessionIdentity: @unchecked Sendable {
    /// Keychain-backed in a real run, memory-only under the UI-test seam: the
    /// seam's rule is that the Keychain of the simulator it runs on is not
    /// its to write (see `UITestSeam`), and the fixture `/me` would otherwise
    /// overwrite the owner's real identity with a fixture's.
    static let shared: SessionIdentity = {
        #if DEBUG
        if UITestSeam.isActive { return SessionIdentity(load: { nil }, save: { _ in }) }
        #endif
        return SessionIdentity(load: TokenStore.loadOwner, save: TokenStore.saveOwner)
    }()

    private let lock = NSLock()
    private var mirror: String?
    private let save: (String?) -> Void

    /// `load` runs once, here. After that the mirror is the answer and every
    /// change goes through `adopt`/`clear`, which write both.
    init(load: () -> String?, save: @escaping (String?) -> Void) {
        self.mirror = load()
        self.save = save
    }

    var userID: String? {
        lock.lock(); defer { lock.unlock() }
        return mirror
    }

    /// Record who `/me` says holds the tokens. Idempotent; a DIFFERENT id
    /// replaces the old one — the server is the authority, and a stored id
    /// that disagrees with it is the stale one.
    func adopt(_ userID: String) {
        lock.lock(); defer { lock.unlock() }
        guard mirror != userID else { return }
        mirror = userID
        save(userID)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        mirror = nil
        save(nil)
    }
}
