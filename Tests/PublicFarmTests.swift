import XCTest
@testable import Agrent

/// A farm's public page on the phone (#536). The farm is synthetic.
@MainActor
final class PublicFarmTests: XCTestCase {

    /// What the farm published, its hidden fields absent; an odd value costs
    /// that value, never the page.
    func testTheProfileDecodes() async throws {
        let farm = try await PublicFarmAPI.decode(from: Data("""
        {"handle":"sintetichna","displayName":"Синтетично стопанство","tagline":"  Пшеница от Добруджа ",
         "about":null,"oblast":"Добрич","crops":["wheat","  ","sunflower"],"logoUrl":"/api/public/media/abc123",
         "photoUrls":["/api/public/media/p1","","https://cdn.example.invalid/x.jpg","/api/public/media/../x"],"extra":42}
        """.utf8))
        XCTAssertEqual(farm.displayName, "Синтетично стопанство")
        XCTAssertEqual(farm.tagline, "Пшеница от Добруджа")
        XCTAssertNil(farm.about)
        XCTAssertEqual(farm.crops, ["wheat", "sunflower"])
        XCTAssertEqual(farm.logoUrl, "/api/public/media/abc123")
        XCTAssertEqual(farm.photoUrls, ["/api/public/media/p1"], "only our media route is followed")
        let bare = try await PublicFarmAPI.decode(from: Data(#"{"handle":"x","displayName":"Х"}"#.utf8))
        XCTAssertEqual(bare.crops, [])
        XCTAssertNil(bare.logoUrl)
    }

    /// The handle in the path only, escaped; private and missing are one
    /// answer.
    func testThePathsAndTheNotPublicAnswer() {
        XCTAssertEqual(PublicFarmAPI.path("a b"), "/api/public/farms/a%20b")
        XCTAssertTrue(PublicFarmAPI.isOurMedia("/api/public/media/h1"))
        XCTAssertFalse(PublicFarmAPI.isOurMedia("/api/account/avatar/u1"))
        XCTAssertTrue(PublicFarmAPI.isNotPublic(APIClient.APIError.http(status: 404, code: "NOT_FOUND", message: nil)))
        XCTAssertFalse(PublicFarmAPI.isNotPublic(URLError(.notConnectedToInternet)))
    }

    /// Only our host's `/f/{handle}`, one segment: anything else stays the
    /// system's.
    func testOnlyAFarmLinkOfOursOpensTheScreen() throws {
        func handle(_ s: String) throws -> String? { PublicProfileLink.handle(from: try XCTUnwrap(URL(string: s))) }
        XCTAssertEqual(try handle("https://app.agrent.bg/f/sintetichna"), "sintetichna")
        XCTAssertEqual(try handle("https://app.agrent.bg/f/sintetichna/"), "sintetichna")
        XCTAssertEqual(try handle("https://app.agrent.bg/f/%D0%BF%D0%BE%D0%B1%D0%B5%D0%B4%D0%B0"), "победа")
        XCTAssertNil(try handle("https://example.com/f/sintetichna"), "not our host")
        XCTAssertNil(try handle("https://app.agrent.bg/m/thread"), "a link this screen is not for")
        XCTAssertNil(try handle("https://app.agrent.bg/f/a/b"))
        XCTAssertNil(try handle("https://app.agrent.bg/f/"))
        XCTAssertEqual(AppRoute.publicFarm(handle: "x").home, .exchange)
    }
}
