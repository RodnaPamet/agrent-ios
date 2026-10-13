import Foundation
import Security

/// Tokens live in the Keychain, never UserDefaults — a refresh token in
/// UserDefaults is readable from a backup and survives an uninstall.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked`: a farm
/// phone in a pocket must still refresh in the background.
struct Tokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// This session's account has not accepted the terms yet (a first Sign
    /// in with Apple, agrent-ios#193): every farm and person route answers
    /// 403 until it does. Kept WITH the pair, so it lasts exactly as long as
    /// the session — a relaunch, or a reinstall that keeps the Keychain,
    /// opens on the terms screen again, and Изход takes it away with the
    /// tokens. Carried across a refresh by `APIClient`. Absent on every pair
    /// stored before it existed, which reads as not pending.
    var termsPending: Bool? = nil
    /// This session's account is suspended (agrent-ios#283): a route answered
    /// `403 ACCOUNT_SUSPENDED`, which a new sign-in only meets again. Kept
    /// with the pair for the reason `termsPending` is — a relaunch opens on
    /// the suspended screen, Изход takes it away — and taken off by the first
    /// `/me` that answers 200, which is the suspension lifted. Set and cleared
    /// by `APIClient` only.
    var suspended: Bool? = nil
    /// While suspended: when the person's OWN deletion runs. `/me`'s refusal
    /// carries it only when the server would honour a cancel (agri-saas
    /// #1670), so nil is both "none pending" and "not theirs to stop" — and
    /// the suspended screen offers the stop for a date, never without one.
    var suspendedErasesAt: Date? = nil

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-30) }
}

enum TokenStore {
    private static let service = "bg.agrent.app.tokens"
    private static let account = "current"

    // MARK: - One lock for every write of the pair (agrent-ios#289)
    //
    // `APIClient` writes the pair from its actor — a refresh's commit, the
    // terms and suspension marks — and only for the session the request was
    // made under: it reads the stored pair, compares the refresh token, and
    // writes. Изход's clear and a sign-in's save run on the main actor. And
    // `save` is a delete then an add. So an Изход landing between the
    // actor's check and its add was UNDONE: the person who left had their
    // pair back. A few Keychain calls wide, never seen — and nothing ruled
    // it out. Every write now holds this lock, and the late ones compare and
    // write inside it (`update(ifRefreshToken:)`, `clear(ifRefreshToken:)`).
    //
    // `NSLock`, not `Mutex` (iOS 18) or `OSAllocatedUnfairLock`, whose
    // `withLock` wants a `@Sendable` body that a caller's mutation is not.
    // Never re-entered: the locked bodies call the unlocked `write`/`delete`.
    private static let lock = NSLock()

    static func save(_ tokens: Tokens) {
        lock.withLock { write(tokens) }
    }

    /// Change the stored pair only if it is still the session whose refresh
    /// token is `expected`; nil when it is not, or there is none. Returns the
    /// pair as stored afterwards, written only if `change` changed it.
    @discardableResult
    static func update(ifRefreshToken expected: String, _ change: (inout Tokens) -> Void) -> Tokens? {
        lock.withLock {
            guard let changed = swapped(load(), expected: expected, change) else { return nil }
            if changed.after != changed.before { write(changed.after) }
            return changed.after
        }
    }

    /// The same for whatever session is stored now — for the one write that
    /// is the CURRENT session's by construction (`APIClient.termsAccepted`).
    static func updateCurrent(_ change: (inout Tokens) -> Void) {
        lock.withLock {
            guard var stored = load() else { return }
            let before = stored
            change(&stored)
            if stored != before { write(stored) }
        }
    }

    /// The decision `update` makes, pure — the Keychain is the owner's on the
    /// simulator the tests run on, so they read this rather than write it.
    static func swapped(_ stored: Tokens?, expected: String,
                        _ change: (inout Tokens) -> Void) -> (before: Tokens, after: Tokens)? {
        guard let stored, stored.refreshToken == expected else { return nil }
        var after = stored
        change(&after)
        return (stored, after)
    }

    private static func write(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Tokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    /// The tokens AND whose they were.
    ///
    /// The identity goes with them because an identity that outlives its
    /// tokens is worse than none: the next sign-in would read and write the
    /// cache under the previous person's key until its own `/me` answered.
    /// Every path that clears tokens — Изход, and the 401 that kills a
    /// refresh — therefore clears the owner too, without having to remember.
    static func clear() {
        lock.withLock { delete() }
        SessionIdentity.shared.clear()
    }

    /// Clear only if the stored pair is still the session whose refresh
    /// token is `expected` — a refused refresh kills ITS session, never the
    /// one that signed in meanwhile. Returns whether it cleared.
    @discardableResult
    static func clear(ifRefreshToken expected: String) -> Bool {
        let cleared = lock.withLock {
            guard load()?.refreshToken == expected else { return false }
            delete()
            return true
        }
        if cleared { SessionIdentity.shared.clear() }
        return cleared
    }

    private static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    // MARK: - the owner (`SessionIdentity`'s persistence)

    /// A second item under the same service rather than a field on `Tokens`:
    /// the refresh path builds a fresh `Tokens` from the server's reply and
    /// would silently drop a field it does not know about. The owner changes
    /// at sign-in and sign-out only; the pair rotates every few minutes.
    private static let ownerAccount = "owner"

    static func saveOwner(_ userID: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ownerAccount,
        ]
        SecItemDelete(query as CFDictionary)
        guard let userID else { return }
        var add = query
        add[kSecValueData as String] = Data(userID.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadOwner() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ownerAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
