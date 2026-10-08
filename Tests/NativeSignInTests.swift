import AuthenticationServices
import XCTest
@testable import Agrent

/// Sign in with Apple and in-app terms acceptance (agrent-ios#193, P4.4).
/// Nothing here reaches Apple or the server: the nonce, the shapes and the
/// words are pure, and the terms store is driven with fakes.
@MainActor
final class AppleSignInTests: XCTestCase {

    // MARK: - The nonce

    /// Fresh on every call, and long enough not to be guessed.
    func testEveryNonceIsFresh() {
        let nonces = (0..<50).map { _ in AppleSignIn.makeNonce() }
        XCTAssertEqual(Set(nonces).count, nonces.count, "a nonce came round twice")
        XCTAssertTrue(nonces.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
    }

    /// SHA-256, lowercase hex — agri-saas `hashNonce`, byte for byte, or the
    /// token's nonce never matches and every sign-in is `invalid_grant`.
    func testTheHashIsTheServers() {
        XCTAssertEqual(AppleSignIn.hashed("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Apple gets the HASH; each request gets its own; and the nonce is
    /// spent by the answer, whatever it was — a retry is a new request.
    func testEachAppleRequestHasItsOwnNonceAndSpendsIt() async {
        let auth = AuthClient()
        let first = ASAuthorizationAppleIDProvider().createRequest()
        auth.prepareAppleRequest(first)
        XCTAssertTrue(auth.appleRequestInFlight)
        XCTAssertEqual(first.requestedScopes, [.fullName, .email], "the email is how the account is found")
        let firstNonce = try? XCTUnwrap(first.nonce)
        XCTAssertEqual(firstNonce?.count, 64, "Apple was given something other than the hash")

        let second = ASAuthorizationAppleIDProvider().createRequest()
        auth.prepareAppleRequest(second)
        XCTAssertNotEqual(second.nonce, first.nonce, "a retry reused the nonce — the server reads that as a replay")

        await auth.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)))
        XCTAssertFalse(auth.appleRequestInFlight, "a nonce outlived its answer")
        XCTAssertEqual(auth.state, .signedOut, "a cancel is not a failure")
    }

    /// Apple's own sheet failing is not the server's refusal.
    func testAnAppleSheetFailureSaysItIsThisDevice() async {
        let auth = AuthClient()
        auth.prepareAppleRequest(ASAuthorizationAppleIDProvider().createRequest())
        await auth.completeAppleSignIn(.failure(ASAuthorizationError(.failed)))
        XCTAssertEqual(auth.state, .failed(AppleSignIn.Text.unavailableHere))
        XCTAssertFalse(auth.appleRequestInFlight)
    }

    // MARK: - The wire

    func testTheBodyCarriesTheRawNonce() throws {
        let body = try JSONEncoder().encode(AppleSignIn.Request(identityToken: "t", nonce: "raw"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["identityToken": "t", "nonce": "raw"])
    }

    /// `termsPending` read leniently: absent is not pending.
    func testTheGrantReadsTermsPending() throws {
        func grant(_ extra: String) throws -> AppleSignIn.Granted {
            let json = #"{"accessToken":"a","refreshToken":"r","tokenType":"Bearer","expiresIn":900,"refreshExpiresAt":"2026-11-08T00:00:00.000Z""#
                + extra + "}"
            return try JSONDecoder().decode(AppleSignIn.Granted.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try grant(#","termsPending":true"#).termsPending)
        XCTAssertFalse(try grant(#","termsPending":false"#).termsPending)
        XCTAssertFalse(try grant("").termsPending, "an older server's answer read as pending")
    }

    /// The refusals, in the server's bare-string shape, and their words.
    func testTheRefusalsHaveTheirOwnWords() {
        func code(_ json: String) -> String? { APIClient.envelope(from: Data(json.utf8))?.code }
        XCTAssertEqual(AppleSignIn.message(status: 503, code: code(#"{"error":"apple_sign_in_disabled"}"#)),
                       AppleSignIn.Text.notAvailable)
        XCTAssertEqual(AppleSignIn.message(status: 404, code: nil), AppleSignIn.Text.notAvailable,
                       "a server without the route is «not switched on», not a failure")
        XCTAssertEqual(AppleSignIn.message(status: 400, code: code(#"{"error":"email_required"}"#)),
                       AppleSignIn.Text.emailRequired)
        // Every token failure is one code, and one sentence: try again.
        XCTAssertEqual(AppleSignIn.message(status: 400, code: code(#"{"error":"invalid_grant"}"#)),
                       AppleSignIn.Text.failed)
        for text in [AppleSignIn.Text.notAvailable, AppleSignIn.Text.failed,
                     AppleSignIn.Text.emailRequired, AppleSignIn.Text.unavailableHere] {
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    func testTheProvidersAreTheServersIds() {
        XCTAssertEqual(AuthClient.Provider.google.rawValue, "google")
        XCTAssertEqual(AuthClient.Provider.microsoft.rawValue, "microsoft-entra-id")
    }

    // MARK: - Pending terms live with the session

    /// A pair stored before the field existed is not pending; a pending one
    /// round-trips.
    func testPendingTermsAreKeptWithTheTokens() throws {
        let old = #"{"accessToken":"a","refreshToken":"r","expiresAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(Tokens.self, from: Data(old.utf8)).termsPending)
        let pending = Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0),
                             termsPending: true)
        let again = try JSONDecoder().decode(Tokens.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(again.termsPending, true)
    }
}

/// The terms screen's store: the version SHOWN is the version sent, and a
/// change of terms under an open screen is asked again — never answered with
/// the server's `currentVersion`.
@MainActor
final class TermsAcceptanceTests: XCTestCase {

    private final class Server {
        var versions: [String]
        var refuseFirstAsStale = false
        private(set) var sent: [TermsAPI.Accept] = []
        init(_ versions: [String]) { self.versions = versions }

        func current() throws -> TermsAPI.Current {
            TermsAPI.Current(version: versions.count > 1 ? versions.removeFirst() : versions[0], url: "/terms")
        }

        func accept(_ body: TermsAPI.Accept) throws -> TermsAPI.Accepted {
            sent.append(body)
            if refuseFirstAsStale, sent.count == 1 {
                throw APIClient.APIError.http(status: 400, code: "terms_version_stale", message: nil,
                                              params: ["currentVersion": "v2"])
            }
            return TermsAPI.Accepted(ok: true, version: body.termsVersion)
        }
    }

    private func store(_ server: Server) -> TermsStore {
        TermsStore(fetch: { try server.current() }, send: { try server.accept($0) })
    }

    func testTheShownVersionIsTheOneAccepted() async {
        let server = Server(["v1"])
        let terms = store(server)
        await terms.load()
        XCTAssertEqual(terms.state, .ready(TermsAPI.Current(version: "v1", url: "/terms")))
        let landed = await terms.accept()
        XCTAssertTrue(landed)
        XCTAssertEqual(server.sent, [TermsAPI.Accept(shown: "v1")])
        XCTAssertTrue(server.sent[0].acceptedTerms, "consent sent as anything but literally true")
    }

    /// Stale: the new version is fetched and shown, and nothing is resent
    /// until the person accepts again.
    func testChangedTermsAreShownAndAskedAgain() async {
        let server = Server(["v1", "v2"])
        server.refuseFirstAsStale = true
        let terms = store(server)
        await terms.load()
        let first = await terms.accept()
        XCTAssertFalse(first)
        XCTAssertEqual(terms.acceptFailure, TermsText.changed)
        XCTAssertEqual(terms.state, .ready(TermsAPI.Current(version: "v2", url: "/terms")))
        XCTAssertEqual(server.sent.map(\.termsVersion), ["v1"],
                       "consent was resent for a version the person had not seen")

        let second = await terms.accept()
        XCTAssertTrue(second)
        XCTAssertEqual(server.sent.map(\.termsVersion), ["v1", "v2"])
    }

    func testTermsThatCannotBeReadSaySo() async {
        let terms = TermsStore(fetch: { throw URLError(.notConnectedToInternet) }, send: { _ in
            XCTFail("sent consent with no terms on screen")
            return TermsAPI.Accepted(ok: true, version: "x")
        })
        await terms.load()
        XCTAssertEqual(terms.state, .failed(TermsText.unavailable))
        let landed = await terms.accept()
        XCTAssertFalse(landed)
    }

    /// `/terms` is relative — the product has more than one host.
    func testTheTermsPageIsOnTheApiHost() {
        XCTAssertEqual(TermsAPI.Current(version: "v", url: "/terms").page?.absoluteString,
                       "https://app.agrent.bg/terms")
        XCTAssertEqual(TermsAPI.Current(version: "v", url: "https://example.invalid/t").page?.absoluteString,
                       "https://example.invalid/t")
    }

    /// Bulgarian sentences; the one Latin word allowed is the product's name.
    func testTheWordsAreBulgarianSentences() {
        for text in [TermsText.lead, TermsText.changed, TermsText.unavailable] {
            XCTAssertTrue(text.hasSuffix("."), text)
            let rest = text.replacingOccurrences(of: "Agrent", with: "")
            XCTAssertNil(rest.range(of: "[A-Za-z]", options: .regularExpression), "Latin in: \(text)")
        }
    }
}
