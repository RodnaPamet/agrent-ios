import XCTest
@testable import Agrent

/// THE SEAM, CHECKED IN BOTH DIRECTIONS.
///
/// `Agrent/Debug/UITestSeam.swift` lets a UI test reach a screen behind
/// sign-in on a simulator that has never signed in. Two things have to be
/// true about it and they pull in opposite directions:
///
///   - with the launch argument it must serve every screen the suite walks;
///   - without it, a debug build must behave exactly as it always did.
///
/// This file holds the second one directly — the unit suite IS a debug build
/// launched without the argument, so `testTheSeamIsOffInAnOrdinaryDebugRun`
/// is not a simulation of the case, it is the case — and it holds the routing
/// and the payloads for the first. What it CANNOT hold is the wiring:
/// `FixtureURLProtocol.canInit` returns `UITestSeam.isActive`, which is false
/// here by construction, so nothing in this process can make the protocol
/// answer a request. That half is proved by launching the app on a simulator
/// with and without the argument; the result of that run is in the pull
/// request, not in this file.
///
/// ── Provenance of the fixtures this adds ──
///
/// `auth-me`, `journal-list`, `tasks-list`, `items`, `units-all` and
/// `units-rate` are SYNTHETIC, written for this seam, and deliberately so —
/// the same reason `Tests/Fixtures/README.md` gives for the locations pair.
/// The real payloads are one farm's operators, their names and their
/// catalogue, and this repo is public. What is NOT invented is the SHAPE:
/// every field and every nullability here is taken from the model that
/// decodes it, and `testEveryCataloguedFixtureDecodesTheWayItsScreenWillRead`
/// puts each file through the app's own decode function rather than through
/// a fresh `JSONDecoder`.
///
/// Three shapes are in there on purpose because they have each broken a
/// screen before:
///
///   - `journal-list` carries a `type` this build does not know, which
///     `LogEntryType` must render as «Друг вид» rather than failing the whole
///     list (see its header — six cases against the server's ten);
///   - `tasks-list` row 2 has `key: null` and `severity: null`, the two
///     nullable fields `WorkItemSummary` documents as having been declared
///     non-optional once;
///   - `items[].defaultUnit` has NO `name`, because `/items` does not send
///     one and `/units` does — the asymmetry that broke the product picker.
final class FixtureSeamTests: XCTestCase {

    // MARK: - the seam is off unless asked for

    /// MERELY BEING A DEBUG BUILD MUST CHANGE NOTHING.
    ///
    /// This suite runs in the app's own process, in the Debug configuration,
    /// launched by `xcodebuild test` with no `AGRENT_UITEST_FIXTURES` in its
    /// argument vector. So this is the ordinary debug run, asking whether the
    /// seam switched itself on.
    func testTheSeamIsOffInAnOrdinaryDebugRun() {
        XCTAssertFalse(
            ProcessInfo.processInfo.arguments.contains(UITestSeam.launchArgument),
            "this suite must NOT be launched with the seam's argument, or the "
            + "assertion below proves nothing"
        )
        XCTAssertFalse(UITestSeam.isActive)
        XCTAssertFalse(
            FixtureURLProtocol.canInit(
                with: URLRequest(url: Config.baseURL.appending(path: MeAPI.path))
            ),
            "the fixture protocol would have intercepted a real request"
        )
    }

    /// The argument carries no leading dash, so `UserDefaults`' argument
    /// domain cannot mistake it for a preference and install it for the life
    /// of the process.
    func testTheLaunchArgumentCannotBecomeADefaultsKey() {
        XCTAssertFalse(UITestSeam.launchArgument.hasPrefix("-"))
        XCTAssertNil(UserDefaults.standard.object(forKey: UITestSeam.launchArgument))
    }

    // MARK: - routing

    /// Every path the app actually builds, against the fixture it must reach.
    ///
    /// Written as the API enums rather than as literals: a route that moves
    /// takes its fixture with it, and a route that moves and DOESN'T is what
    /// this test exists to fail on.
    func testTheCatalogueAnswersTheAppsOwnPaths() {
        let expected: [(String, String)] = [
            (MeAPI.path, "auth-me"),
            (JournalAPI.listPath, "journal-list"),
            (LocationsAPI.listPath, "locations-list"),
            (LocationsAPI.parcelsPath(FixtureCatalogue.fixtureLocationID), "locations-parcels"),
            (LocationsAPI.itemsPath, "items"),
            (LocationsAPI.allUnitsPath, "units-all"),
            (LocationsAPI.rateUnitsPath, "units-rate"),
            (WorkItemAPI.listPath, "tasks-list"),
            (CalculatorAPI.path, "calculator-sample"),
            (ExchangeAPI.listingsPath, "exchange-listings"),
            (ExchangeAPI.myListingsPath, "exchange-my-listings"),
        ]
        for (pathAndQuery, fixture) in expected {
            let (path, query) = FixtureCatalogue.split(pathAndQuery)
            XCTAssertEqual(
                FixtureCatalogue.fixtureName(path: path, query: query), fixture,
                "\(pathAndQuery) should be answered by \(fixture).json"
            )
        }
    }

    /// THE ONE ROUTE WHERE THE QUERY DECIDES.
    ///
    /// `/units` is every unit and `/units?measure=RATE` is the four dose
    /// rates. Serving the first for the second would put `kg`, `ha`, `t` and
    /// `%` in a dose picker, which is a screenshot that looks fine and is
    /// wrong.
    func testTheUnitsRouteIsAnsweredByItsQuery() {
        let all = FixtureCatalogue.split(LocationsAPI.allUnitsPath)
        let rate = FixtureCatalogue.split(LocationsAPI.rateUnitsPath)
        XCTAssertEqual(all.path, rate.path, "the premise of this test is that the paths are equal")
        XCTAssertNil(all.query)
        XCTAssertEqual(rate.query, "measure=RATE")
        XCTAssertEqual(FixtureCatalogue.fixtureName(path: all.path, query: all.query), "units-all")
        XCTAssertEqual(FixtureCatalogue.fixtureName(path: rate.path, query: rate.query), "units-rate")
    }

    /// A second page of the journal is the SAME recorded page.
    ///
    /// The fixture has `nextCursor: null` so the app never asks for one, but
    /// path-only matching is what makes that robust rather than lucky: a
    /// cursor in the query must not turn into `NO_FIXTURE` and a blank screen
    /// halfway through a screenshot run.
    func testAJournalCursorPageStillFindsTheFixture() {
        let (path, query) = FixtureCatalogue.split(JournalAPI.path(cursor: "opaque-cursor"))
        XCTAssertNotNil(query)
        XCTAssertEqual(FixtureCatalogue.fixtureName(path: path, query: query), "journal-list")
    }

    /// AND THE QUIET DIRECTION: routes with no recorded payload must return
    /// nil, so `FixtureURLProtocol` answers 501 `NO_FIXTURE` and the screen
    /// shows a server error instead of invented farm data.
    func testUncoveredRoutesHaveNoFixture() {
        for pathAndQuery in [
            DashboardAPI.agPath,
            "/api/t/\(Config.tenantSlug)/admin",
            WorkItemAPI.detailPath("tsk_fixture_1"),
            LocationsAPI.parcelsPath("loc_that_does_not_exist"),
            "/api/auth/token/refresh",
        ] {
            let (path, query) = FixtureCatalogue.split(pathAndQuery)
            XCTAssertNil(
                FixtureCatalogue.fixtureName(path: path, query: query),
                "\(pathAndQuery) has no recorded payload and must not be answered 200"
            )
        }
    }

    /// The location id in the parcels key is the one the list fixture holds.
    ///
    /// Spelled by hand in `FixtureCatalogue`, because a path cannot be built
    /// from a file the catalogue has not read. Held against the file here so
    /// that correcting one and not the other fails in CI rather than as an
    /// empty map in a screenshot.
    func testTheParcelsKeyNamesTheLocationInTheListFixture() async throws {
        let locations = try await LocationsAPI.decodeList(from: try fixture("locations-list"))
        XCTAssertEqual(locations.map(\.id), [FixtureCatalogue.fixtureLocationID])
    }

    // MARK: - payloads

    /// EVERY CATALOGUED FIXTURE, THROUGH THE APP'S OWN DECODE.
    ///
    /// Not through a fresh `JSONDecoder` — `APIClient`'s accepts ISO 8601
    /// both with and WITHOUT fractional seconds, and a test that brought its
    /// own decoder would pass on a payload the app then fails to read. Each
    /// route's real decode function is called, which is the function the
    /// screen calls.
    func testEveryCataloguedFixtureDecodesTheWayItsScreenWillRead() async throws {
        for (name, decode) in Self.decoders {
            let data = try fixture(name)
            do {
                try await decode(data)
            } catch {
                XCTFail("\(name).json does not decode: \(error)")
            }
        }
    }

    /// THE COUNTER THAT STOPS THIS BEING A CHECK OF THREE FIXTURES OUT OF
    /// ELEVEN.
    ///
    /// Adding a route to `FixtureCatalogue` and forgetting the decoder here
    /// would leave the new payload unchecked while the suite stayed green —
    /// which is exactly how a component adopted by three of the five screens
    /// that needed it reported that it passed.
    func testEveryCataloguedFixtureHasADecoderInThisFile() {
        let catalogued = Set(FixtureCatalogue.allFixtureNames)
        let checked = Set(Self.decoders.map(\.0))
        XCTAssertEqual(
            catalogued.subtracting(checked), [],
            "these fixtures are served to the app but nothing here proves they decode"
        )
        XCTAssertEqual(
            checked.subtracting(catalogued), [],
            "these decoders name a fixture the catalogue no longer serves"
        )
        XCTAssertFalse(catalogued.isEmpty, "the catalogue is empty and this file guards nothing")
    }

    /// A refusal from the seam reaches the app as a CODE, not as bytes.
    ///
    /// `FixtureURLProtocol` builds `{error:{code,message}}` because that is
    /// the server's own refusal shape, and `APIClient.envelope(from:)` is
    /// what every screen's error path reads. If the two ever disagree, a
    /// `NO_FIXTURE` would surface as «Грешка от сървъра (501)» with no way to
    /// tell it apart from a real one.
    func testARefusalFromTheSeamReadsBackAsItsCode() {
        let envelope = APIClient.envelope(
            from: FixtureURLProtocol.envelope("NO_FIXTURE", "no recorded payload for /x")
        )
        XCTAssertEqual(envelope?.code, "NO_FIXTURE")
        XCTAssertEqual(envelope?.message, "no recorded payload for /x")
    }

    // MARK: - helpers

    /// One entry per fixture the catalogue can serve, calling the decode the
    /// app calls on that route.
    private static let decoders: [(String, (Data) async throws -> Void)] = [
        ("auth-me", { _ = try await MeAPI.decode(from: $0) }),
        ("journal-list", { _ = try await JournalAPI.decodeList(from: $0) }),
        ("locations-list", { _ = try await LocationsAPI.decodeList(from: $0) }),
        ("locations-parcels", { _ = try await LocationsAPI.decodeParcels(from: $0) }),
        ("items", { _ = try await LocationsAPI.decodeItems(from: $0) }),
        ("units-all", { _ = try await LocationsAPI.decodeUnits(from: $0) }),
        ("units-rate", { _ = try await LocationsAPI.decodeUnits(from: $0) }),
        ("tasks-list", { _ = try await WorkItemAPI.decodeList(from: $0) }),
        ("calculator-sample", { _ = try await CalculatorAPI.decode(from: $0) }),
        ("exchange-listings", { _ = try await ExchangeAPI.decodeListings(from: $0) }),
        ("exchange-my-listings", { _ = try await ExchangeAPI.decodeMyListings(from: $0) }),
    ]

    /// A MISSING FIXTURE IS A FAILURE, NOT A SKIP.
    ///
    /// `XCTSkip` was the obvious spelling and is the wrong one: a skipped
    /// test reports green, so deleting a fixture the seam serves would leave
    /// the suite passing and the screen blank.
    private struct FixtureNotInBundle: Error, CustomStringConvertible {
        let name: String
        var description: String {
            "\(name).json is not in the test bundle — is it still under Tests/Fixtures?"
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw FixtureNotInBundle(name: name)
        }
        return try Data(contentsOf: url)
    }
}
