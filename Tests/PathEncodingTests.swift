import XCTest
@testable import Agrent

/// What every path builder puts ON THE WIRE, not what it returns
/// (agrent-ios#122).
///
/// The builders' strings are an intermediate form. Asserting on them is how
/// #122 hid: `FarmRiskAPI.analysisPath("par_holes")` returned a string that
/// looked deliberately escaped, and `url.path` — the decoded view — handed the
/// same string back, so every check that looked was satisfied while the
/// server was sent `par%255Fholes`. So each case here goes through
/// `APIClient.url(for:)`, the one function every request's URL comes from,
/// and reads `path(percentEncoded: true)`: the bytes that leave the phone.
///
/// Two ids exercise each builder. `a/b?c` is the id that could move a request:
/// raw, its `/` adds a path segment and its `?` starts a query. `par_holes`
/// is #122's own id — `_` is RFC 3986 unreserved and must pass untouched. A
/// cuid (what production ids are) is checked too, byte-identical, because
/// this change must not move any request that works today.
final class PathEncodingTests: XCTestCase {

    private let t = "/api/t/\(Config.tenantSlug)"
    private let cuid = "cmg1abc2d0000xyz"

    private func wire(_ pathAndQuery: String) throws -> String {
        try APIClient.url(for: pathAndQuery).path(percentEncoded: true)
    }

    private func wireQuery(_ pathAndQuery: String) throws -> String? {
        try APIClient.url(for: pathAndQuery).query(percentEncoded: true)
    }

    // MARK: - #122

    /// THE ISSUE. Escaped against `.alphanumerics` and then escaped again by
    /// `URLComponents.path`'s setter: `par_holes` → `par%5Fholes` →
    /// `par%255Fholes`, a 404 for any id with a `_` or `-`.
    func testTheRiskAnalysisIdIsEncodedExactlyOnce() throws {
        XCTAssertEqual(try wire(FarmRiskAPI.analysisPath("par_holes")),
                       "\(t)/agro/parcels/par_holes/analysis")
        XCTAssertEqual(try wire(FarmRiskAPI.analysisPath("a/b?c")),
                       "\(t)/agro/parcels/a%2Fb%3Fc/analysis")
        XCTAssertEqual(try wire(FarmRiskAPI.analysisPath(cuid)),
                       "\(t)/agro/parcels/\(cuid)/analysis")
    }

    // MARK: - the same class, elsewhere

    /// Messaging escaped its ids (#114) and so was double-encoded for exactly
    /// the characters it escaped; the listing detail did not escape at all.
    func testExchangeIdsAreEncodedExactlyOnce() throws {
        let x = "\(t)/exchange"
        XCTAssertEqual(try wire(ExchangeAPI.threadPath("a/b?c")), "\(x)/threads/a%2Fb%3Fc")
        XCTAssertEqual(try wire(ExchangeAPI.messagesPath(threadID: "a/b?c")),
                       "\(x)/threads/a%2Fb%3Fc/messages")
        XCTAssertEqual(try wire(ExchangeAPI.messagePath(messageID: "../x")), "\(x)/messages/..%2Fx")
        XCTAssertEqual(try wire(ExchangeAPI.openThreadPath(listingID: "a/b?c")),
                       "\(x)/listings/a%2Fb%3Fc/thread")
        XCTAssertEqual(try wire(ExchangeAPI.listingPath("a/b?c")), "\(x)/listings/a%2Fb%3Fc")
        XCTAssertEqual(try wire(ExchangeAPI.listingPath("par_holes")), "\(x)/listings/par_holes")
        XCTAssertEqual(try wire(ExchangeAPI.threadPath(cuid)), "\(x)/threads/\(cuid)")
    }

    func testAdminMembershipIdsStayInTheirSegment() throws {
        XCTAssertEqual(try wire(AdminAPI.deactivatePath("a/b?c")),
                       "\(t)/admin/members/a%2Fb%3Fc/deactivate")
        XCTAssertEqual(try wire(AdminAPI.reactivatePath("par_holes")),
                       "\(t)/admin/members/par_holes/reactivate")
        XCTAssertEqual(try wire(AdminAPI.reactivatePath(cuid)),
                       "\(t)/admin/members/\(cuid)/reactivate")
    }

    func testLocationIdsStayInTheirSegment() throws {
        let l = "\(t)/locations"
        XCTAssertEqual(try wire(LocationsAPI.parcelsPath("a/b?c")), "\(l)/a%2Fb%3Fc/parcels")
        XCTAssertEqual(try wire(LocationsAPI.operationsPath("a/b?c")), "\(l)/a%2Fb%3Fc/operations")
        XCTAssertEqual(try wire(LocationsAPI.parcelPath(locationID: "a/b?c", parcelID: "par_holes")),
                       "\(l)/a%2Fb%3Fc/parcels/par_holes")
        XCTAssertEqual(try wire(LocationsAPI.parcelsPath(cuid)), "\(l)/\(cuid)/parcels")
    }

    func testParcelHistoryIdsStayInTheirSegment() throws {
        let p = "\(t)/agro/parcels"
        XCTAssertEqual(try wire(ParcelHistoryAPI.cropSeasonsPath("a/b?c")),
                       "\(p)/a%2Fb%3Fc/crop-seasons")
        XCTAssertEqual(try wire(ParcelHistoryAPI.weedObservationsPath("a/b?c")),
                       "\(p)/a%2Fb%3Fc/weed-observations")
        XCTAssertEqual(try wire(ParcelHistoryAPI.cropSeasonPath(parcelID: "par_holes", seasonID: "a/b?c")),
                       "\(p)/par_holes/crop-seasons/a%2Fb%3Fc")
        XCTAssertEqual(
            try wire(ParcelHistoryAPI.weedObservationPath(parcelID: "par_holes", observationID: "a/b?c")),
            "\(p)/par_holes/weed-observations/a%2Fb%3Fc"
        )
        // The query must survive a path segment that carried a `?`.
        let history = ParcelHistoryAPI.historyPath(parcelID: "a/b?c", limit: 5)
        XCTAssertEqual(try wire(history), "\(p)/a%2Fb%3Fc/history")
        XCTAssertEqual(try wireQuery(history), "limit=5")
    }

    func testSpatialImportIdsStayInTheirSegment() throws {
        let l = "\(t)/locations"
        XCTAssertEqual(try wire(SpatialImportAPI.uploadPath(locationID: "a/b?c")),
                       "\(l)/a%2Fb%3Fc/spatial-import")
        XCTAssertEqual(try wire(SpatialImportAPI.jobPath(locationID: "par_holes", jobID: "a/b?c")),
                       "\(l)/par_holes/spatial-import/a%2Fb%3Fc")
    }

    func testTaskIdsStayInTheirSegment() throws {
        XCTAssertEqual(try wire(WorkItemAPI.detailPath("a/b?c")), "\(t)/tasks/a%2Fb%3Fc")
        XCTAssertEqual(try wire(WorkItemAPI.statusPath("a/b?c")), "\(t)/tasks/a%2Fb%3Fc/status")
        XCTAssertEqual(try wire(WorkItemAPI.detailPath(cuid)), "\(t)/tasks/\(cuid)")
    }

    // MARK: - query values, once

    /// A base64 cursor's `+`, `=` and `/` and a Cyrillic search term reach
    /// the wire encoded exactly once, and decode back to what was given.
    func testQueryValuesAreEncodedExactlyOnce() throws {
        let cursor = "ab+c/d=="
        let threads = ExchangeAPI.threadsPath(cursor: cursor)
        XCTAssertEqual(try wireQuery(threads), "cursor=ab%2Bc%2Fd%3D%3D")
        XCTAssertEqual(try wireQuery(JournalAPI.path(cursor: cursor)),
                       "limit=50&cursor=ab%2Bc%2Fd%3D%3D")

        var search = ExchangeQuery()
        search.text = "пшеница"
        let q = try XCTUnwrap(try wireQuery(ExchangeAPI.listingsPath(search)))
        let items = URLComponents(string: "x:?\(q)")?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "пшеница")
    }

    // MARK: - url(for:) refuses rather than traps

    /// `percentEncodedPath`/`percentEncodedQuery` `fatalError` on malformed
    /// input (measured). A builder that forgets `URLEscape` must cost one
    /// request a `badURL`, not the whole app. Before #122 a raw space in a
    /// QUERY was already a crash; these would have taken the test run down.
    func testMalformedInputThrowsInsteadOfTrapping() {
        for bad in ["\(t)/a b", "\(t)/жито", "\(t)/50%", "\(t)/%zz",
                    "\(t)/x?q=a b", "\(t)/x?q=жито", "\(t)/x?q=%G0"] {
            XCTAssertThrowsError(try APIClient.url(for: bad), bad)
        }
    }

    func testTheValidatorAcceptsWhatTheBuildersProduce() {
        XCTAssertTrue(URLEscape.isPercentEncoded("/a/%2Fb%3f/c-._~", allowed: .urlPathAllowed))
        XCTAssertFalse(URLEscape.isPercentEncoded("/a/%2", allowed: .urlPathAllowed))
        XCTAssertFalse(URLEscape.isPercentEncoded("/a?b", allowed: .urlPathAllowed))
        XCTAssertTrue(URLEscape.isPercentEncoded("a=1&b=%D0%B6?", allowed: .urlQueryAllowed))
        XCTAssertEqual(URLEscape.segment("жито"), "%D0%B6%D0%B8%D1%82%D0%BE")
    }
}
