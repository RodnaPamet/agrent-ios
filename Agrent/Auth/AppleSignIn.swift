import CryptoKit
import Foundation

/// Sign in with Apple, the app's half (agrent-ios#193, P4.4), against
/// `POST /api/auth/native/apple` (agri-saas #1404).
///
/// ── One call, no browser ──
///
/// Unlike Google and Microsoft there is no `/start`, no code and no PKCE:
/// Apple's sheet hands the app an identity token, and one POST trades it for
/// this app's token pair. The server verifies the token against Apple's
/// public keys and the app's bundle id (`APPLE_BUNDLE_ID`), so the app keeps
/// no Apple secret at all.
///
/// ── The nonce is single-use, and that shapes every retry ──
///
/// Each attempt makes a fresh random nonce, gives Apple its SHA-256 (Apple
/// embeds it in the token) and sends the RAW value here. The server checks the
/// hash AND claims the nonce once, by INSERT against a unique index, BEFORE it
/// answers — so a retry with the same nonce is, to the server, exactly a
/// replay, and is refused even if the first answer never arrived. A failed
/// attempt is therefore a new Apple request with a new nonce, never the same
/// payload sent again (`AuthClient.prepareAppleRequest`). An `invalid_grant`
/// straight after a network failure is that, not a bad credential.
enum AppleSignIn {
    static let path = "/api/auth/native/apple"

    /// A fresh raw nonce: 32 random bytes as hex. `UInt8.random` draws from
    /// the system's cryptographic generator.
    static func makeNonce() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// What Apple is given, and what the server compares: SHA-256, lowercase
    /// hex — agri-saas `hashNonce`, byte for byte.
    static func hashed(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The request body. `nonce` is the RAW value; the server hashes it.
    struct Request: Encodable, Equatable, Sendable {
        let identityToken: String
        let nonce: String
    }

    /// `200 { accessToken, refreshToken, tokenType, expiresIn,
    /// refreshExpiresAt, termsPending }`.
    ///
    /// `termsPending` is read leniently: absent or unreadable is false, as an
    /// older server meant it. True means a brand-new account that has not
    /// accepted the terms — every farm and person route answers 403 until the
    /// app shows them and calls accept-terms (`TermsAcceptanceView`).
    struct Granted: Decodable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let termsPending: Bool

        private enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expiresIn, termsPending }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            refreshToken = try c.decode(String.self, forKey: .refreshToken)
            expiresIn = try c.decode(Int.self, forKey: .expiresIn)
            termsPending = (try? c.decodeIfPresent(Bool.self, forKey: .termsPending)) ?? false
        }
    }

    /// The sentence for a refused exchange.
    ///
    /// The server makes every token failure one `400 invalid_grant` — bad
    /// signature, wrong audience, expired, mismatched or replayed nonce — so
    /// this does not branch on the reason: it asks for another try, which is
    /// a new nonce. Two answers are worth their own words: Apple sign-in not
    /// switched on (503, or 404 while the route is not deployed), which is
    /// not the person's failure, and a first authorisation without an email.
    static func message(status: Int, code: String?) -> String {
        switch (status, code) {
        case (503, _), (404, _): Text.notAvailable
        case (400, "email_required"): Text.emailRequired
        default: Text.failed
        }
    }

    enum Text {
        /// Not the person's failure: the server has no Apple audience yet,
        /// or does not have the route. Google and Microsoft still work.
        static let notAvailable = "Входът с Apple все още не е включен. Използвайте Google или Microsoft."
        static let failed = "Входът с Apple не успя. Опитайте отново."
        /// Apple sends the email on the FIRST authorisation only, and the
        /// server cannot create an account without one.
        static let emailRequired = "Apple не изпрати имейл адрес. В Настройки спрете използването на "
            + "Apple ID за Agrent и опитайте отново, като споделите имейла."
        /// Apple's own sheet failed — no iCloud account on the phone, or the
        /// capability missing from this build.
        static let unavailableHere = "Входът с Apple не е достъпен на това устройство."
    }
}
