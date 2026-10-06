import UIKit
import XCTest
@testable import Agrent

/// The Админ account card (owner, 2026-10-04): the initials rule, the
/// picture's route and decoding, the in-memory store, the spoken label and
/// the circle's measured contrast. Nothing here reaches the network: the
/// store is built with a fake fetch, never with `APIClient`.
@MainActor
final class AccountCardTests: XCTestCase {

    // MARK: - Initials

    func testTwoWordsGiveFirstAndLast() {
        XCTAssertEqual(AccountInitials.of(name: "Ada Lovelace", email: nil), "AL")
        // The web's rule: FIRST and LAST word, not the first two.
        XCTAssertEqual(AccountInitials.of(name: "Иван Петров Иванов", email: "x@y.bg"), "ИИ")
    }

    func testCyrillicNamesAreUppercased() {
        XCTAssertEqual(AccountInitials.of(name: "мария георгиева", email: nil), "МГ")
        XCTAssertEqual(AccountInitials.of(name: "Йордан Щерев", email: nil), "ЙЩ")
    }

    /// «Й» spelled as И + combining breve is ONE letter, not «И» and a stray
    /// mark.
    func testACombiningLetterStaysWhole() {
        let decomposed = "\u{0418}\u{0306}ордан"
        XCTAssertEqual(AccountInitials.of(name: decomposed, email: nil)?.count, 1)
        XCTAssertEqual(AccountInitials.of(name: decomposed, email: nil)?.unicodeScalars.count, 2)
    }

    func testASingleWordGivesOneLetter() {
        XCTAssertEqual(AccountInitials.of(name: "Иван", email: "ivan@x.bg"), "И")
        XCTAssertEqual(AccountInitials.of(name: "  Иван \n", email: nil), "И")
    }

    func testTheEmailStandsInWhenThereIsNoName() {
        XCTAssertEqual(AccountInitials.of(name: nil, email: "ivan.petrov@farm.bg"), "IP")
        XCTAssertEqual(AccountInitials.of(name: "   ", email: "ivan_petrov@farm.bg"), "IP")
        XCTAssertEqual(AccountInitials.of(name: "", email: "ivan@farm.bg"), "I")
        // The `+tag` is a mailbox filter, and the domain is not a name.
        XCTAssertEqual(AccountInitials.of(name: nil, email: "ivan+agrent@farm.bg"), "I")
    }

    func testNothingToDrawFromIsNil() {
        XCTAssertNil(AccountInitials.of(name: nil, email: nil))
        XCTAssertNil(AccountInitials.of(name: " ", email: ""))
        XCTAssertNil(AccountInitials.of(name: nil, email: "@farm.bg"))
        XCTAssertNil(AccountInitials.of(name: nil, email: "..@farm.bg"))
    }

    // MARK: - The spoken label

    func testOneSentenceForVoiceOver() {
        XCTAssertEqual(AccountCard.spokenLabel(name: "Иван Петров", email: "ivan@farm.bg"),
                       "Вписан като Иван Петров, ivan@farm.bg")
        XCTAssertEqual(AccountCard.spokenLabel(name: nil, email: "ivan@farm.bg"),
                       "Вписан като ivan@farm.bg")
        XCTAssertEqual(AccountCard.spokenLabel(name: " Иван ", email: "  "),
                       "Вписан като Иван")
    }

    // MARK: - avatarUrl, decoded from /me

    private func me(_ avatarJSON: String?) throws -> CurrentUser {
        let field = avatarJSON.map { #","avatarUrl":\#($0)"# } ?? ""
        let json = #"{"user":{"id":"usr_a","name":"А","email":null,"role":"OWNER","bottomTabOrder":null\#(field)},"tenant":null,"featureFlags":{}}"#
        return try JSONDecoder().decode(CurrentUser.self, from: Data(json.utf8))
    }

    func testAvatarUrlDecodesNullRelativeAndAbsolute() throws {
        XCTAssertNil(try me("null").avatarUrl)
        XCTAssertEqual(try me(#""/api/account/avatar/usr_a""#).avatarUrl, "/api/account/avatar/usr_a")
        XCTAssertEqual(try me(#""https://photos.example.invalid/a.jpg""#).avatarUrl,
                       "https://photos.example.invalid/a.jpg")
    }

    /// The spec: "may be ABSENT from a server older than this field — treat
    /// absent as null". And a value of the wrong type costs the picture,
    /// never the identity (`DecoderToleranceTests`' rule, one level down).
    func testAnAbsentOrUnreadableAvatarUrlIsNilAndTheUserSurvives() throws {
        let absent = try me(nil)
        XCTAssertNil(absent.avatarUrl)
        XCTAssertEqual(absent.id, "usr_a")
        let wrongType = try me("42")
        XCTAssertNil(wrongType.avatarUrl)
        XCTAssertEqual(wrongType.id, "usr_a", "an unreadable avatarUrl must not fail /me")
    }

    // MARK: - Which shape goes where

    func testTheTwoShapesAreToldApart() throws {
        XCTAssertNil(AccountAvatarAPI.source(nil))
        XCTAssertNil(AccountAvatarAPI.source(""))
        XCTAssertEqual(AccountAvatarAPI.source("/api/account/avatar/usr_a"),
                       .api(path: "/api/account/avatar/usr_a"))
        let photo = try XCTUnwrap(URL(string: "https://photos.example.invalid/a/b=s96-c"))
        XCTAssertEqual(AccountAvatarAPI.source(photo.absoluteString), .external(photo))
    }

    /// Everything that is neither a clean root-relative path nor an https
    /// URL falls back to initials, and asks nothing.
    func testAnythingButHTTPSOrARootRelativePathIsRefused() {
        for value in [
            "http://photos.example.invalid/a.jpg",       // in clear
            "HTTP://photos.example.invalid/a.jpg",
            "ftp://photos.example.invalid/a.jpg",
            "data:image/png;base64,AAAA",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "//photos.example.invalid/a.jpg",            // protocol-relative: ANOTHER host
            "/\\photos.example.invalid/a.jpg",
            "https://user:pw@photos.example.invalid/a",  // credentials in the URL
            "https:///no-host",
            "/api/account/avatar/has a space",           // not a path APIClient builds
            "api/account/avatar/usr_a",                  // neither shape
        ] {
            XCTAssertNil(AccountAvatarAPI.source(value), "\(value) must be refused")
        }
    }

    /// THE SECURITY PROPERTY: the bearer goes to the API host for a relative
    /// value and NOWHERE for an absolute one. Both are the builders the live
    /// fetches use (`APIClient.perform`, `AccountAvatarAPI.fetchExternal`).
    func testOnlyTheRelativeShapeCarriesTheBearer() throws {
        let relative = try XCTUnwrap(AccountAvatarAPI.source("/api/account/avatar/usr_a"))
        guard case .api(let path) = relative else { return XCTFail("relative read as \(relative)") }
        let api = try APIClient.request(for: path, method: "GET", accessToken: "test-access")
        XCTAssertEqual(api.value(forHTTPHeaderField: "Authorization"), "Bearer test-access",
                       "positive control: the relative shape is authorised")
        XCTAssertEqual(api.url?.host, Config.baseURL.host, "a relative value resolves on the API host")
        XCTAssertEqual(api.url?.path, "/api/account/avatar/usr_a")
        XCTAssertEqual(api.value(forHTTPHeaderField: ClientHeader.name), ClientHeader.value)

        let absolute = try XCTUnwrap(AccountAvatarAPI.source("https://photos.example.invalid/a.jpg"))
        guard case .external(let url) = absolute else { return XCTFail("absolute read as \(absolute)") }
        let external = AccountAvatarAPI.externalRequest(for: url)
        XCTAssertNil(external.value(forHTTPHeaderField: "Authorization"),
                     "the bearer must never reach a third-party host")
        XCTAssertNil(external.allHTTPHeaderFields?["Cookie"])
        XCTAssertFalse(external.httpShouldHandleCookies)
        XCTAssertEqual(external.url, url, "an absolute value is fetched exactly as given")
        XCTAssertEqual(external.httpMethod, "GET")
        XCTAssertEqual(external.value(forHTTPHeaderField: ClientHeader.name), ClientHeader.value,
                       "every request is stamped, a third-party one included")
    }

    /// The session for the third-party fetch keeps nothing and sends nothing
    /// of this app's: no URL cache, no cookies, no credential store.
    func testTheThirdPartySessionHoldsNoCredentials() {
        let configuration = NoURLCache.thirdPartyConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpAdditionalHeaders?["Authorization"])
        XCTAssertNil(NoURLCache.thirdPartySession.configuration.urlCache)
        XCTAssertNil(NoURLCache.thirdPartySession.configuration.httpCookieStorage)
    }

    // MARK: - The bytes

    func testImageBytesDecodeAndAnythingElseDoesNot() throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        XCTAssertNotNil(AccountAvatarAPI.image(from: png))
        XCTAssertNil(AccountAvatarAPI.image(from: Data()))
        // A JSON error body, which is what a 4xx through a misread would be.
        XCTAssertNil(AccountAvatarAPI.image(from: Data(#"{"error":"nope"}"#.utf8)))
    }

    func testMoreThanTheCapIsRefusedUnread() {
        XCTAssertEqual(AccountAvatarAPI.maxBytes, 5 * 1024 * 1024)
        XCTAssertNil(AccountAvatarAPI.image(from: Data(count: AccountAvatarAPI.maxBytes + 1)))
    }

    /// A large picture is decoded DOWN to what the circle can show.
    func testALargePictureIsDownsampled() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format)
            .image { ctx in
                UIColor.blue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
            }
        let image = try XCTUnwrap(AccountAvatarAPI.image(from: try XCTUnwrap(big.jpegData(compressionQuality: 0.5))))
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(max(cg.width, cg.height), AccountAvatarAPI.maxPixelSize)
    }

    // MARK: - The store

    private static let relative = "/api/account/avatar/usr_a"
    private static let absolute = "https://photos.example.invalid/a.jpg"

    func testNullAsksNothingAndDrawsInitials() async {
        var asked: [AccountAvatarAPI.Source] = []
        let store = AccountAvatarStore { asked.append($0); return Data() }
        await store.load(for: "usr_a", avatarURL: nil)
        XCTAssertEqual(asked, [], "no picture means no request — not a speculative one by user id")
        XCTAssertNil(store.key)
        XCTAssertNil(store.image(for: "usr_a", avatarURL: nil))
    }

    func testANonHTTPSValueAsksNothing() async {
        var asked: [AccountAvatarAPI.Source] = []
        let store = AccountAvatarStore { asked.append($0); return Data() }
        await store.load(for: "usr_a", avatarURL: "http://photos.example.invalid/a.jpg")
        XCTAssertEqual(asked, [])
        XCTAssertNil(store.image(for: "usr_a", avatarURL: "http://photos.example.invalid/a.jpg"))
    }

    func testEachShapeIsFetchedThroughItsOwnRoute() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var asked: [AccountAvatarAPI.Source] = []
        let store = AccountAvatarStore { asked.append($0); return png }
        await store.load(for: "usr_a", avatarURL: Self.relative)
        await store.load(for: "usr_b", avatarURL: Self.absolute)
        XCTAssertEqual(asked, [
            .api(path: Self.relative),
            .external(try XCTUnwrap(URL(string: Self.absolute))),
        ])
        XCTAssertNotNil(store.image(for: "usr_b", avatarURL: Self.absolute))
    }

    func testAPictureIsHeldForItsOwnerAndValueOnly() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var asked = 0
        let store = AccountAvatarStore { _ in asked += 1; return png }

        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertNotNil(store.image(for: "usr_a", avatarURL: Self.relative))
        XCTAssertNil(store.image(for: "usr_b", avatarURL: Self.relative), "A's picture must never answer for B")
        XCTAssertNil(store.image(for: "usr_a", avatarURL: Self.absolute), "nor for a value it was not fetched from")

        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertEqual(asked, 1, "a held picture is not asked for again")
    }

    /// #147's foreground refresh: a CHANGED `avatarUrl` fetches again; a
    /// removed one turns back into initials with no request.
    func testAChangedValueIsFetchedAndARemovedOneForgotten() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var asked: [AccountAvatarAPI.Source] = []
        let store = AccountAvatarStore { asked.append($0); return png }

        await store.load(for: "usr_a", avatarURL: Self.absolute)
        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked.last, .api(path: Self.relative))
        XCTAssertNotNil(store.image(for: "usr_a", avatarURL: Self.relative))

        await store.load(for: "usr_a", avatarURL: nil)
        XCTAssertEqual(asked.count, 2, "removal asks nothing")
        XCTAssertNil(store.key)
        XCTAssertEqual(store.avatar, .unknown)
        XCTAssertNil(store.image(for: "usr_a", avatarURL: Self.relative))
    }

    func testA404MeansInitialsAndIsNotAskedAgain() async {
        var calls = 0
        let store = AccountAvatarStore { _ in
            calls += 1
            throw APIClient.APIError.http(status: 404, code: nil, message: nil,
                                          params: nil, retryAfterSeconds: nil)
        }
        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertEqual(store.avatar, AccountAvatarStore.Avatar.none)
        XCTAssertNil(store.image(for: "usr_a", avatarURL: Self.relative))
        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertEqual(calls, 1)
    }

    /// A third-party host's final answers — gone, or too big — are initials
    /// for this value, not a retry every time Админ opens.
    func testAThirdPartyRefusalOrOversizeIsFinal() async {
        for failure in [AccountAvatarAPI.Unavailable.gone(status: 404), .tooLarge] {
            var calls = 0
            let store = AccountAvatarStore { _ in calls += 1; throw failure }
            await store.load(for: "usr_a", avatarURL: Self.absolute)
            await store.load(for: "usr_a", avatarURL: Self.absolute)
            XCTAssertEqual(store.avatar, AccountAvatarStore.Avatar.none, "\(failure)")
            XCTAssertEqual(calls, 1, "\(failure)")
        }
    }

    /// Offline, a 5xx, or the fixture seam's 501: initials now, ask again
    /// next time rather than remembering "no picture" for a whole session.
    func testATransientFailureIsAskedAgain() async {
        var calls = 0
        let store = AccountAvatarStore { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertEqual(store.avatar, .unknown)
        await store.load(for: "usr_a", avatarURL: Self.relative)
        XCTAssertEqual(calls, 2)
    }

    /// #142: Изход leaves nothing of A's face behind.
    func testSignOutForgetsThePicture() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        let store = AccountAvatarStore { _ in png }
        await store.load(for: "usr_a", avatarURL: Self.absolute)
        XCTAssertNotNil(store.image(for: "usr_a", avatarURL: Self.absolute))
        store.reset()
        XCTAssertNil(store.key)
        XCTAssertEqual(store.avatar, .unknown)
        XCTAssertNil(store.image(for: "usr_a", avatarURL: Self.absolute))
    }

    /// And the shared one is actually on the sign-out path, not just
    /// resettable: `resetUserState()` must empty it.
    func testResetUserStateEmptiesTheSharedStore() {
        AccountAvatarStore.shared.adoptForTesting(userID: "usr_a", avatarURL: Self.relative,
                                                  image: Self.onePixel())
        XCTAssertNotNil(AccountAvatarStore.shared.image(for: "usr_a", avatarURL: Self.relative),
                        "positive control")
        SessionReset.resetUserState()
        XCTAssertNil(AccountAvatarStore.shared.key)
        XCTAssertEqual(AccountAvatarStore.shared.avatar, .unknown)
        XCTAssertNil(AccountAvatarStore.shared.image(for: "usr_a", avatarURL: Self.relative))
    }

    /// A picture for A that answers after Изход is dropped.
    func testAnAnswerFromTheOldSessionIsDropped() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var release: CheckedContinuation<Void, Never>?
        let store = AccountAvatarStore { _ in
            await withCheckedContinuation { release = $0 }
            return png
        }
        let load = Task { await store.load(for: "usr_a", avatarURL: Self.relative) }
        while release == nil { await Task.yield() }
        SessionEpoch.advance()
        store.reset()
        release?.resume()
        await load.value
        XCTAssertNil(store.image(for: "usr_a", avatarURL: Self.relative))
        XCTAssertNil(store.key)
    }

    /// An answer for the value the refresh has since REPLACED is not this
    /// picture either — same session, different `avatarUrl`.
    func testAnAnswerForAReplacedValueIsDropped() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var release: CheckedContinuation<Void, Never>?
        let store = AccountAvatarStore { source in
            if source == .api(path: Self.relative) { await withCheckedContinuation { release = $0 } }
            return png
        }
        let old = Task { await store.load(for: "usr_a", avatarURL: Self.relative) }
        while release == nil { await Task.yield() }
        await store.load(for: "usr_a", avatarURL: nil)
        release?.resume()
        await old.value
        XCTAssertNil(store.key, "the removed avatar came back from a late answer")
        XCTAssertNil(store.image(for: "usr_a", avatarURL: Self.relative))
    }

    // MARK: - The circle's contrast, from the constants it is drawn with

    func testTheInitialsOnTheCircleMeetAA() {
        typealias A = Palette.Avatar
        let pairs: [(String, UInt32, UInt32, Double)] = [
            ("light", A.inkLight, A.fillLight, 5.83),
            ("light, Increase Contrast", A.inkLight, A.fillLightIncreased, 8.60),
            ("dark", A.inkDark, A.fillDark, 8.73),
        ]
        for (name, ink, fill, documented) in pairs {
            let ratio = Self.contrast(ink, fill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name): \(ratio)")
            XCTAssertEqual(ratio, documented, accuracy: 0.01,
                           "\(name): Palette.Avatar's comment says \(documented), measured \(ratio)")
        }
        XCTAssertGreaterThan(Self.contrast(A.inkLight, A.fillLightIncreased),
                             Self.contrast(A.inkLight, A.fillLight),
                             "Increase Contrast must raise the ratio, not just change the colour")
    }

    // MARK: - helpers

    private static func onePixel() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    /// WCAG 2.x contrast ratio of two sRGB hex colours.
    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func linear(_ hex: UInt32, shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ hex: UInt32) -> Double {
            let r: Double = 0.2126 * linear(hex, shift: 16)
            let g: Double = 0.7152 * linear(hex, shift: 8)
            let b: Double = 0.0722 * linear(hex, shift: 0)
            return r + g + b
        }
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}
