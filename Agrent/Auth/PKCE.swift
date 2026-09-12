import CryptoKit
import Foundation

/// PKCE pair. The server accepts S256 only — it rejects `plain` outright
/// (`unsupported_code_challenge_method`), which is the correct strictness.
struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncodedString()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// base64url, unpadded — RFC 7636. Standard base64 is NOT interchangeable
    /// here: `+` and `/` are not URL-safe and the server compares strings.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
