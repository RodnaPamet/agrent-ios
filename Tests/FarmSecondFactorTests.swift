import XCTest
@testable import Agrent

/// #689: a farm that owes its second factor is asked for it in the app, for
/// that farm, and released without a new sign-in. The verify call is a seam:
/// a real one spends a rate-limited attempt against a person's authenticator.
@MainActor
final class FarmSecondFactorTests: XCTestCase {

    private func prompt(open farm: String = "ferma-2") -> FarmSecondFactor {
        let p = FarmSecondFactor()
        p.refused(by: farm, open: farm)
        return p
    }

    func testTheFarmIsReadFromAFarmPath() {
        XCTAssertEqual(FarmPath.slug(in: "/api/t/ferma-2/journal?limit=50"), "ferma-2")
        XCTAssertEqual(FarmPath.slug(in: "/api/t/ferma-2"), "ferma-2")
        XCTAssertNil(FarmPath.slug(in: "/api/t//journal"), "an unscoped path names no farm")
        XCTAssertNil(FarmPath.slug(in: "/api/auth/me"), "a person's path is no farm's")
    }

    func testOnlyTheOpenFarmIsAskedAbout() {
        let p = FarmSecondFactor()
        // A background request to another farm — a push registration at launch.
        p.refused(by: "ferma-1", open: "ferma-2")
        XCTAssertNil(p.owed, "no prompt for a farm the person is not looking at")
        p.refused(by: "ferma-2", open: "ferma-2")
        XCTAssertEqual(p.owed?.slug, "ferma-2")
        p.refused(by: nil, open: "ferma-2")
        XCTAssertEqual(p.owed?.slug, "ferma-2", "a refusal naming no farm changes nothing")
    }

    func testAnAcceptedCodeReleasesTheFarmAndRebuildsItsScreens() async {
        let p = prompt()
        final class Seen: @unchecked Sendable { var call: (String, String)? }
        let seen = Seen()
        await p.submit("123456") { code, farm in
            seen.call = (code, farm)
            return .init(success: true, remaining: nil)
        }
        XCTAssertEqual(seen.call?.0, "123456")
        XCTAssertEqual(seen.call?.1, "ferma-2", "the code is checked against THAT farm (agri-saas #3186)")
        XCTAssertNil(p.owed)
        XCTAssertEqual(p.releases, 1)
        XCTAssertNil(p.error)
    }

    func testAWrongCodeSaysHowManyAttemptsAreLeft() async {
        let p = prompt()
        await p.submit("000000") { _, _ in .init(success: false, remaining: 3) }
        XCTAssertEqual(p.owed?.slug, "ferma-2", "still asking")
        XCTAssertEqual(p.error, AppleSignIn.Text.wrongCode(attemptsLeft: 3))
        XCTAssertEqual(p.refusals, 1)
        XCTAssertEqual(p.releases, 0)

        await p.submit("000000") { _, _ in .init(success: false, remaining: nil) }
        XCTAssertEqual(p.error, AppleSignIn.Text.wrongCodeAgain)
    }

    func testARefusedRequestIsSaidInBulgarian() async throws {
        let p = prompt()
        await p.submit("123456") { _, _ in
            throw APIClient.APIError.http(status: 429, code: nil, message: "Too many verification attempts.")
        }
        let error = try XCTUnwrap(p.error)
        XCTAssertFalse(error.contains("Too many"), "the server's English never reaches the person")
        XCTAssertEqual(p.owed?.slug, "ferma-2")
    }

    func testAShortCodeIsNotSent() async {
        let p = prompt()
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        await p.submit("12345") { _, _ in count.n += 1; return .init(success: true, remaining: nil) }
        XCTAssertEqual(count.n, 0)
    }

    func testAnAnswerForAClosedPromptIsDropped() async {
        let p = prompt()
        await p.submit("123456") { _, _ in
            await MainActor.run { p.reset() }
            return .init(success: true, remaining: nil)
        }
        XCTAssertEqual(p.releases, 0, "a prompt closed while the code was out releases nothing")
    }

    func testTheVerifyRouteIsTheOpenFarms() {
        XCTAssertEqual(FarmSecondFactorAPI.verifyPath(in: "ferma-2"),
                       "/api/t/ferma-2/security/mfa/challenge/verify")
    }
}
