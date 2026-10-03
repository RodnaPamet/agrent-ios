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

    // MARK: - The picture's route and bytes

    func testThePathIsTheServeRouteWithTheIdAsOneSegment() {
        XCTAssertEqual(AccountAvatarAPI.path(userID: "usr_1"), "/api/account/avatar/usr_1")
        // An id cannot add a segment or start a query.
        XCTAssertEqual(AccountAvatarAPI.path(userID: "a/b?c"), "/api/account/avatar/a%2Fb%3Fc")
    }

    func testImageBytesDecodeAndAnythingElseDoesNot() throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        XCTAssertNotNil(AccountAvatarAPI.image(from: png))
        XCTAssertNil(AccountAvatarAPI.image(from: Data()))
        // A JSON error body, which is what a 4xx through a misread would be.
        XCTAssertNil(AccountAvatarAPI.image(from: Data(#"{"error":"nope"}"#.utf8)))
    }

    // MARK: - The store

    func testAPictureIsHeldForItsOwnerOnly() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var asked: [String] = []
        let store = AccountAvatarStore { id in asked.append(id); return png }

        await store.load(for: "usr_a")
        XCTAssertNotNil(store.image(for: "usr_a"))
        XCTAssertNil(store.image(for: "usr_b"), "A's picture must never answer for B")

        await store.load(for: "usr_a")
        XCTAssertEqual(asked, ["usr_a"], "a held picture is not asked for again")
    }

    func testA404MeansInitialsAndIsNotAskedAgain() async {
        var calls = 0
        let store = AccountAvatarStore { _ in
            calls += 1
            throw APIClient.APIError.http(status: 404, code: nil, message: nil,
                                          params: nil, retryAfterSeconds: nil)
        }
        await store.load(for: "usr_a")
        XCTAssertEqual(store.avatar, AccountAvatarStore.Avatar.none)
        XCTAssertNil(store.image(for: "usr_a"))
        await store.load(for: "usr_a")
        XCTAssertEqual(calls, 1)
    }

    /// Offline, a 5xx, or the fixture seam's 501: initials now, ask again
    /// next time rather than remembering "no picture" for a whole session.
    func testATransientFailureIsAskedAgain() async {
        var calls = 0
        let store = AccountAvatarStore { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        await store.load(for: "usr_a")
        XCTAssertEqual(store.avatar, .unknown)
        await store.load(for: "usr_a")
        XCTAssertEqual(calls, 2)
    }

    /// #142: Изход leaves nothing of A's face behind.
    func testSignOutForgetsThePicture() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        let store = AccountAvatarStore { _ in png }
        await store.load(for: "usr_a")
        XCTAssertNotNil(store.image(for: "usr_a"))
        store.reset()
        XCTAssertNil(store.userID)
        XCTAssertEqual(store.avatar, .unknown)
        XCTAssertNil(store.image(for: "usr_a"))
    }

    /// And the shared one is actually on the sign-out path, not just
    /// resettable: `resetUserState()` must empty it.
    func testResetUserStateEmptiesTheSharedStore() {
        AccountAvatarStore.shared.adoptForTesting(userID: "usr_a", image: Self.onePixel())
        XCTAssertNotNil(AccountAvatarStore.shared.image(for: "usr_a"), "positive control")
        SessionReset.resetUserState()
        XCTAssertNil(AccountAvatarStore.shared.userID)
        XCTAssertEqual(AccountAvatarStore.shared.avatar, .unknown)
        XCTAssertNil(AccountAvatarStore.shared.image(for: "usr_a"))
    }

    /// A picture for A that answers after Изход is dropped.
    func testAnAnswerFromTheOldSessionIsDropped() async throws {
        let png = try XCTUnwrap(Self.onePixel().pngData())
        var release: CheckedContinuation<Void, Never>?
        let store = AccountAvatarStore { _ in
            await withCheckedContinuation { release = $0 }
            return png
        }
        let load = Task { await store.load(for: "usr_a") }
        while release == nil { await Task.yield() }
        SessionEpoch.advance()
        store.reset()
        release?.resume()
        await load.value
        XCTAssertNil(store.image(for: "usr_a"))
        XCTAssertNil(store.userID)
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
