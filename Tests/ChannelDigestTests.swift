import XCTest
@testable import Agrent

/// Профил's channel digest switch (#620) against agri-saas #3076. Every
/// write is a closure that records what it was asked; nothing is sent.
@MainActor
final class ChannelDigestTests: XCTestCase {

    private func me(_ digest: String) async throws -> CurrentUser {
        try await MeAPI.decode(from: Data("""
        {"user":{"id":"u1","name":"Иван","email":null,"role":"OWNER"\(digest)},"featureFlags":{}}
        """.utf8))
    }

    func testMeCarriesTheSwitchOrNothing() async throws {
        let on = try await me(#","channelDigestOptIn":true"#)
        XCTAssertEqual(on.channelDigestOptIn, true)
        XCTAssertEqual(on.inFarm(role: "ADMIN").channelDigestOptIn, true, "a farm's role does not change a person's switch")
        let older = try await me("")
        XCTAssertNil(older.channelDigestOptIn, "a server before the field: the switch is not drawn")
        let odd = try await me(#","channelDigestOptIn":"yes""#)
        XCTAssertNil(odd.channelDigestOptIn, "an unreadable value costs the switch, never the identity")
        XCTAssertEqual(odd.id, "u1")
    }

    func testThePath() {
        XCTAssertEqual(ChannelDigestAPI.path, "/api/account/channel-digest")
    }

    func testTurningOnSendsOnceAndKeepsTheServersAnswer() async {
        var sent: [Bool] = []
        let digest = ChannelDigestSwitch(on: false) { sent.append($0); return $0 }
        await digest.set(true)
        await digest.set(true)
        XCTAssertEqual(sent, [true], "the same value twice is one write")
        XCTAssertTrue(digest.on)
        XCTAssertFalse(digest.saving)
    }

    func testARefusalPutsTheSwitchBackAndSaysWhy() async throws {
        let digest = ChannelDigestSwitch(on: false) { _ in
            throw APIClient.APIError.http(status: 400, code: "INVALID_DIGEST_OPT_IN", message: "optIn required")
        }
        await digest.set(true)
        XCTAssertFalse(digest.on, "it did not change, so it does not say it did")
        XCTAssertTrue(digest.showsFailure)
        let failure = try XCTUnwrap(digest.failure)
        XCTAssertNotNil(failure.range(of: "\\p{Cyrillic}", options: .regularExpression), failure)
    }

    func testAFreshMeStandsUnlessAWriteIsOut() {
        let digest = ChannelDigestSwitch(on: false) { $0 }
        digest.adopt(true)
        XCTAssertTrue(digest.on)
        digest.adopt(nil)
        XCTAssertTrue(digest.on, "no answer changes nothing")
    }

    /// Additive: the words promise a recap and say the rest stays.
    func testTheWordsSayItAddsAndHoldsNothingBack() {
        XCTAssertTrue(ChannelDigestSwitch.note.contains("7:15"))
        XCTAssertTrue(ChannelDigestSwitch.note.contains("Другите известия остават"))
        XCTAssertFalse(ChannelDigestSwitch.title.contains("Групирай"))
        for text in [ChannelDigestSwitch.title, ChannelDigestSwitch.note, ChannelDigestSwitch.failedTitle] {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }
}
