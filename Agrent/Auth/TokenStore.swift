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

    static func save(_ tokens: Tokens) {
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
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        SessionIdentity.shared.clear()
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
