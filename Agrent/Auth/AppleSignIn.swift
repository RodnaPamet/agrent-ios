import CryptoKit
import Foundation

/// Sign in with Apple, the app's half (agrent-ios#193, P4.4), against
/// `POST /api/auth/native/apple` (agri-saas #1404).
///
/// ── One call, no browser ──
///
/// Unlike Google and Microsoft there is no `/start` and no browser: Apple's
/// sheet hands the app an identity token, and one POST trades it for this
/// app's token pair — or, at a farm that requires a second factor, for a
/// ticket the code screen redeems (agri-saas #1649; PKCE binds the two). The server verifies the token against Apple's
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
    ///
    /// `code_challenge` is how this build DECLARES it can collect a second
    /// factor (agri-saas #1649). Without it, a farm that requires one answers
    /// `403 MFA_REQUIRED`, which is what every earlier build handles; with
    /// it, that farm answers `202` with a ticket — a status those builds'
    /// `guard status == 200` would have turned into a nonsense sentence. The
    /// challenge is also the ticket's PKCE binding: its verifier stays in
    /// this process and goes only to `codePath`, so a ticket that leaks
    /// through a log is useless without it.
    struct Request: Encodable, Equatable, Sendable {
        let identityToken: String
        let nonce: String
        let codeChallenge: String

        private enum CodingKeys: String, CodingKey {
            case identityToken, nonce
            case codeChallenge = "code_challenge"
        }
    }

    /// `202 { status: "mfa_required", ticket, expiresIn }`: the identity token
    /// is accepted and the sign-in is INCOMPLETE — the farm requires a second
    /// factor. Not a credential: the ticket authenticates nothing and only
    /// `codePath` redeems it.
    ///
    /// `status` is checked rather than ignored. It is the discriminant this
    /// app asked for so that a ticket can never decode as a grant or a grant
    /// as a ticket; a body without it is refused here, not half-read.
    struct CodeRequired: Decodable, Equatable, Sendable {
        let ticket: String
        /// SECONDS the ticket stays valid — a duration, not a date.
        let expiresIn: TimeInterval

        private enum CodingKeys: String, CodingKey { case status, ticket, expiresIn }

        init(ticket: String, expiresIn: TimeInterval) {
            self.ticket = ticket
            self.expiresIn = expiresIn
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard try c.decode(String.self, forKey: .status) == "mfa_required" else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: c,
                                                       debugDescription: "not a second-factor ticket")
            }
            ticket = try c.decode(String.self, forKey: .ticket)
            expiresIn = try c.decode(TimeInterval.self, forKey: .expiresIn)
        }
    }

    /// What a sign-in with Apple came back as, when it was not refused.
    enum Answer: Equatable, Sendable {
        case granted(Granted)
        case codeRequired(CodeRequired)
    }

    /// The answer for a status and body: 200 is the pair, 202 a ticket, and
    /// anything else nil — a refusal, read from the envelope by the caller.
    /// Each shape is decoded as only itself, so a body that does not match
    /// its status throws rather than becoming the other.
    static func answer(status: Int, data: Data) throws -> Answer? {
        switch status {
        case 200: .granted(try JSONDecoder().decode(Granted.self, from: data))
        case 202: .codeRequired(try JSONDecoder().decode(CodeRequired.self, from: data))
        default: nil
        }
    }

    // MARK: - The second factor (agri-saas #1649, agrent-ios#274)

    /// Redeems a ticket with the six digits from the person's authenticator.
    /// `200` is the same pair as a plain Apple sign-in, `termsPending` and all.
    static let codePath = "/api/auth/native/mfa"

    struct CodeRequest: Encodable, Equatable, Sendable {
        let ticket: String
        let code: String
        let codeVerifier: String

        private enum CodingKeys: String, CodingKey {
            case ticket, code
            case codeVerifier = "code_verifier"
        }
    }

    /// A ticket waiting for its code: what the code screen redeems, and the
    /// moment it stops being redeemable. The deadline is this phone's own
    /// clock plus `expiresIn`, so expiry is known here without asking — the
    /// server answers an expired ticket with the same code as a consumed or
    /// unknown one, on purpose (`codeOutcome`).
    struct PendingCode: Equatable, Sendable {
        let ticket: String
        let verifier: String
        let deadline: Date
    }

    /// What the code screen does with a refusal: say it and let the person
    /// type again, or end this sign-in and send them back to the buttons.
    enum CodeOutcome: Equatable, Sendable {
        case again(String)
        case restart(String)
    }

    /// The refusal of a code, by status and code.
    ///
    /// `MFA_TICKET_INVALID` is one opaque code for expired, consumed, unknown
    /// and mismatched tickets, and is not branched on beyond restarting — but
    /// THIS phone knows whether its own deadline passed, and that is the one
    /// case worth its own words. `attemptsRemaining` comes as an integer; at
    /// 0 the server has already burned the ticket in the same response, so
    /// the sign-in restarts without another call to find that out.
    static func codeOutcome(status: Int, code: String?, params: [String: String]?, expired: Bool) -> CodeOutcome {
        switch (status, code) {
        case (400, "MFA_CODE_INVALID"):
            switch params?["attemptsRemaining"].flatMap({ Int($0) }) {
            case .some(let left) where left <= 0: return .restart(Text.tooManyWrong)
            case .some(let left): return .again(Text.wrongCode(attemptsLeft: left))
            case .none: return .again(Text.wrongCodeAgain)
            }
        case (400, "MFA_CODE_MALFORMED"):
            return .again(Text.sixDigits)
        case (403, "MFA_TICKET_INVALID"):
            return .restart(expired ? Text.codeExpired : Text.startAgain)
        default:
            // A 429, a 5xx, a network edge: not about the code, and the ticket
            // may still be good — unless its time is up.
            return expired ? .restart(Text.codeExpired)
                : .again(UserMessage.httpText(status: status, code: code, message: nil))
        }
    }

    /// The field's text as a code: ASCII digits only, at most six. A pasted
    /// or autofilled «123 456» keeps its digits; anything else is dropped
    /// here rather than spending one of five attempts on the server.
    static func digits(_ text: String) -> String {
        String(text.filter { ("0"..."9").contains($0) }.prefix(6))
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
    /// a new nonce. Four answers are worth their own words: Apple sign-in
    /// not switched on (503, or 404 while the route is not deployed), which
    /// is not the person's failure; a first authorisation without an email;
    /// a farm that requires a second factor this sign-in cannot collect
    /// (agri-saas #1644 — since #1649 only when the check behind it could
    /// not complete, as this build asks for a ticket); and an account with
    /// no authenticator set up at a farm that requires one, which no code
    /// screen can satisfy.
    static func message(status: Int, code: String?) -> String {
        switch (status, code) {
        case (503, _), (404, _): Text.notAvailable
        case (400, "email_required"): Text.emailRequired
        case (400, _): Text.failed
        case (403, "MFA_REQUIRED"): Text.secondFactor
        case (403, "MFA_ENROLLMENT_REQUIRED"): Text.enrollmentRequired
        // Anything else is not about the token — a 429, a 426 for an old
        // build, a 5xx — and the house words already say what each means.
        default: UserMessage.httpText(status: status, code: code, message: nil)
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
        /// The farm may require an authenticator code and this sign-in could
        /// not ask for one. Since agri-saas #1649 a build that sends a
        /// `code_challenge` meets this only when the server could not finish
        /// checking the farm's policy — it refuses rather than let anyone in
        /// unchecked — so a retry can help, and Google and Microsoft, which
        /// ask in their sheet, are the other way in.
        static let secondFactor = "Входът с Apple не можа да поиска код за двуфакторно потвърждение. "
            + "Опитайте отново или влезте с Google или Microsoft."
        /// Apple's own sheet failed — no iCloud account on the phone, or the
        /// capability missing from this build.
        static let unavailableHere = "Входът с Apple не е достъпен на това устройство."

        // ── The second factor ──

        /// The farm requires a code and this account has no authenticator to
        /// produce one, so there is no code to ask for. The remedy is setting
        /// one up, which the web's setup page does — another provider would
        /// meet the same requirement.
        static let enrollmentRequired = "Стопанството изисква двуфакторно потвърждение, а профилът ви още "
            + "няма приложение за кодове. Настройте го в уеб версията и влезте отново."
        static let codeTitle = "Код за потвърждение"
        static let codeExplanation = "Стопанството изисква двуфакторно потвърждение. Въведете шестцифрения "
            + "код от приложението си за кодове."
        static let codeField = "Код"
        static let codePrompt = "6 цифри"
        static let confirm = "Потвърди"
        static let checking = "Проверка на кода"
        /// Bulgarian counts «опит» as «опита» after every number but one.
        static func wrongCode(attemptsLeft: Int) -> String {
            attemptsLeft == 1 ? "Грешен код. Остава 1 опит."
                : "Грешен код. Остават \(attemptsLeft) опита."
        }
        static let wrongCodeAgain = "Грешен код. Опитайте отново."
        static let sixDigits = "Въведете шестте цифри от приложението за кодове."
        static let tooManyWrong = "Твърде много грешни кодове. Влезте отново с Apple."
        static let codeExpired = "Времето за въвеждане на кода изтече. Влезте отново с Apple."
        static let startAgain = "Входът трябва да започне отначало. Влезте отново с Apple."
    }
}
