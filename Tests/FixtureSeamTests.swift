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
/// `auth-me`, `journal-list`, `tasks-list`, `items` and `units-rate` are
/// SYNTHETIC, written for this seam, and deliberately so —
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
///
/// `exchange-threads` and `exchange-thread` (agrent-ios#114) are SYNTHETIC
/// for a stronger reason than the rest: they are private messages between
/// two farms, and no real conversation was captured, opened or written to
/// make them. Their shape is the spec's (`ExchangeThreadSummary`,
/// `ExchangeThread`, `ExchangeMessage`), and they carry a tombstone, a role
/// this build does not know, a null `sellerDisplayName`, a null
/// `olderCursor`, and a closed and a blocked thread — see
/// `Tests/Fixtures/README.md`.
///
/// `admin-*`, `insurance-leads`, `risk-analysis-*`, `dashboard-*` and
/// `trends-*` (agrent-ios#115) are SYNTHETIC too, added when A11yShots moved
/// onto this seam so Админ, Риск, Табло and Новини photograph a render rather
/// than a 501. Same rule: invented values, the model's shape. `admin-farm-
/// profile`'s ЕГН is ten zeros — month 00 is not a date, so it cannot be
/// anybody's — and it is still only ever photographed masked.
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
            (LocationsAPI.rateUnitsPath, "units-rate"),
            (WorkItemAPI.listPath, "tasks-list"),
            (CalculatorAPI.path, "calculator-sample"),
            (CostsAPI.defaultsPath, "costs-defaults"),
            // #245: the same route with the crop named is the crop's sheet.
            (CostsAPI.cropDefaultsPath("WHEAT"), "costs-defaults-crop"),
            (CostsAPI.machineryPath, "costs-machinery"),
            (ExchangeAPI.listingsPath, "exchange-listings"),
            (ExchangeAPI.myListingsPath, "exchange-my-listings"),
            (ExchangeAPI.threadsPath, "exchange-threads"),
            (ExchangeAPI.threadPath(FixtureCatalogue.fixtureThreadID), "exchange-thread"),
            // agrent-ios#115 — the four menu screens A11yShots photographs.
            (AdminAPI.membersPath, "admin-members"),
            (AdminAPI.farmProfilePath, "admin-farm-profile"),
            (FarmRiskAPI.leadsPath, "insurance-leads"),
            (FarmRiskAPI.analysisPath("par_holes"), "risk-analysis-holes"),
            (FarmRiskAPI.analysisPath("par_simple"), "risk-analysis-simple"),
            (FarmRiskAPI.analysisPath("par_nogeom"), "risk-analysis-nogeom"),
            (DashboardAPI.agPath, "dashboard-ag"),
            (DashboardAPI.taskTrendPath(days: DashboardAPI.DefaultWindow.tasks),
             "dashboard-task-trend"),
            (DashboardAPI.fieldBriefingPath, "dashboard-field-briefing"),
            (TrendsAPI.pricesPath(.wheat, range: .month3), "trends-prices"),
            (TrendsAPI.newsPath(.all), "trends-news"),
            // #231: the topics' feed, the catalogue and the choices.
            (TrendsAPI.newsPath(tags: ["subsidies", "wheat"], query: nil, cursor: nil), "trends-news-mine"),
            (TrendsAPI.newsTagsPath, "trends-news-tags"),
            (NewsPreferencesAPI.path, "news-preferences"),
            // agrent-ios#138 — the field-operation task and its lines.
            (WorkItemAPI.detailPath(FixtureCatalogue.fixtureFieldOperationTaskID), "task-detail-fieldop"),
            (FieldOperationAPI.detailPath(FixtureCatalogue.fixtureFieldOperationTaskID),
             "field-operation-detail"),
            // agrent-ios#177 — a plain task and its parcels.
            (WorkItemAPI.detailPath(FixtureCatalogue.fixtureTaskID), "task-detail-task"),
            (WorkItemAPI.parcelsPath(FixtureCatalogue.fixtureTaskID), "task-parcels"),
            // agrent-ios#179 stage 3 — Профил's farm list.
            (FarmsAPI.farmsPath, "me-farms"),
            // agrent-ios#258 — the superuser's prices form.
            (AdminPricesAPI.path, "admin-price-overrides"),
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
    /// wrong. The app asks only for the rates since the product form that
    /// wanted every unit went (#237), so the bare path is served NOTHING —
    /// never the rates by a path match that ignored the query.
    func testTheUnitsRouteIsAnsweredByItsQuery() {
        let rate = FixtureCatalogue.split(LocationsAPI.rateUnitsPath)
        XCTAssertEqual(rate.query, "measure=RATE")
        XCTAssertEqual(FixtureCatalogue.fixtureName(path: rate.path, query: rate.query), "units-rate")
        XCTAssertNil(FixtureCatalogue.fixtureName(path: rate.path, query: nil))
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
            "\(FarmPath.root(for: Config.pinnedFarmSlug))/admin",
            WorkItemAPI.detailPath("tsk_fixture_1"),
            LocationsAPI.parcelsPath("loc_that_does_not_exist"),
            FarmRiskAPI.analysisPath("par_that_does_not_exist"),
            InsuranceCatalogueAPI.path,
            "/api/auth/token/refresh",
            // The Админ account card's picture. NO fixture, on purpose: the
            // fixture `/me` says `avatarUrl: null`, so the card asks nothing
            // and draws initials — the state A11yShots should photograph,
            // since it is what most real accounts show (an upload is
            // optional) and the one whose contrast was measured. Were a
            // fixture ever to name this path, the seam's 501 would still
            // leave it on initials.
            "/api/account/avatar/usr_fixture_owner",
            // THE QUERY DECIDES on these two (#115): the wheat fixture must
            // not answer a maize chart, and «Всички» must not answer a
            // category filter. Each is a different request and has no payload.
            TrendsAPI.pricesPath(.maize, range: .month3),
            TrendsAPI.pricesPath(.wheat, range: .year1),
            TrendsAPI.newsPath(.policy),
            // #138: only the ONE field operation has lines; and a line's
            // MARK path is a write, which no fixture may ever answer — the
            // protocol refuses every non-GET before it looks, and this keeps
            // the table from naming one should that ever change.
            FieldOperationAPI.detailPath("tsk_fixture_1"),
            // #177: only the ONE plain task has parcels.
            WorkItemAPI.parcelsPath("tsk_fixture_1"),
            FieldOperationAPI.linePath(taskID: FixtureCatalogue.fixtureFieldOperationTaskID,
                                       lineID: "opl_synthetic_1"),
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

    /// The Риск keys name the parcels the parcels fixture actually holds, and
    /// each reading file is about the parcel it is served for.
    ///
    /// Both halves matter. `FarmRiskStore.readRisks` asks once per ROW of
    /// `locations-parcels.json`, so a parcel missing from the catalogue is a
    /// `NO_FIXTURE` row in the capture; and a reading whose own `parcelId`
    /// names a different parcel would render under the wrong name without
    /// anything failing, because the store files it by the row it asked for.
    func testTheRiskKeysNameTheParcelsInTheParcelsFixture() async throws {
        let parcels = try await LocationsAPI.decodeParcels(from: try fixture("locations-parcels"))
        XCTAssertEqual(
            Set(parcels.parcels.map(\.id)),
            Set(FixtureCatalogue.fixtureRiskParcels.map(\.parcelID)),
            "every parcel on the Риск screen needs a reading, and no reading may name a ghost"
        )
        for (parcelID, name) in FixtureCatalogue.fixtureRiskParcels {
            let risk = try await FarmRiskAPI.decodeAnalysis(from: try fixture(name))
            XCTAssertEqual(risk.parcelId, parcelID, "\(name).json is about another parcel")
        }
    }

    /// The conversation key names the thread the fixtures actually hold —
    /// the conversation file's own id, and a row of the inbox file, so a
    /// tap on that inbox row under the seam opens a conversation rather
    /// than `NO_FIXTURE`.
    func testTheThreadKeyNamesTheThreadInBothFixtures() async throws {
        let thread = try await ExchangeAPI.decodeThread(from: try fixture("exchange-thread"))
        XCTAssertEqual(thread.id, FixtureCatalogue.fixtureThreadID)
        let inbox = try await ExchangeAPI.decodeThreads(from: try fixture("exchange-threads"))
        XCTAssertTrue(inbox.threads.map(\.id).contains(FixtureCatalogue.fixtureThreadID))
        let row = try XCTUnwrap(inbox.threads.first { $0.id == FixtureCatalogue.fixtureThreadID })
        XCTAssertEqual(row.listingId, thread.listingId, "the two files disagree about the listing")
    }

    /// The field-operation key names the task all three files hold
    /// (agrent-ios#138): a FIELD_OPERATION row in the list, so a tap on it
    /// builds the lines store at all; its detail; and its lines — three of
    /// them, one in each state, which is what the capture is for.
    func testTheFieldOperationKeyNamesTheTaskInAllThreeFixtures() async throws {
        let id = FixtureCatalogue.fixtureFieldOperationTaskID
        let list = try await WorkItemAPI.decodeList(from: try fixture("tasks-list"))
        let row = try XCTUnwrap(list.items.first { $0.id == id }, "the list has no row to tap")
        XCTAssertEqual(row.type, .fieldOperation, "the row would open with no lines section")
        let detail = try await WorkItemAPI.decodeDetail(from: try fixture("task-detail-fieldop"))
        XCTAssertEqual(detail.id, id)
        XCTAssertEqual(detail.type, .fieldOperation)
        let job = try await FieldOperationAPI.decodeDetail(from: try fixture("field-operation-detail"))
        XCTAssertEqual(job.task.id, id)
        XCTAssertEqual(Set(job.lines.map(\.status)), [.pending, .done, .skipped],
                       "the capture is of mixed states")
        // The fixture owner may mark: an OWNER writes. The positive control
        // that the capture shows buttons at all.
        let me = try await MeAPI.decode(from: try fixture("auth-me"))
        XCTAssertTrue(FieldOperationRules.mayMark(me: me, assigneeUserID: job.task.assigneeUserId))
    }

    /// The plain-task key names the task all three files hold (agrent-ios#177):
    /// a row in the list that is NOT a field operation, so a tap builds the
    /// parcels store rather than the lines; its detail; and its parcels —
    /// two with outlines and one without, which is what the capture is for.
    func testThePlainTaskKeyNamesTheTaskInAllThreeFixtures() async throws {
        let id = FixtureCatalogue.fixtureTaskID
        let list = try await WorkItemAPI.decodeList(from: try fixture("tasks-list"))
        let row = try XCTUnwrap(list.items.first { $0.id == id }, "the list has no row to tap")
        XCTAssertNotEqual(row.type, .fieldOperation, "the row would open the lines, not the parcels")
        let detail = try await WorkItemAPI.decodeDetail(from: try fixture("task-detail-task"))
        XCTAssertEqual(detail.id, id)
        XCTAssertEqual(detail.type, row.type)
        let parcels = try await WorkItemAPI.decodeParcels(from: try fixture("task-parcels"))
        XCTAssertEqual(parcels.map(\.name), ["SYNTH-1", "SYNTH-2", "SYNTH-3"])
        let map = try XCTUnwrap(TaskParcelMapContent.linked(parcels), "the capture would have no map")
        XCTAssertEqual(map.marked.count, 2)
        XCTAssertEqual(map.undrawable, 1, "the capture is of a parcel noted under the map")
    }

    /// Paging and polling a conversation under the seam reach the same
    /// recorded page, never `NO_FIXTURE`: the query is ignored on this route.
    /// The fixture's `olderCursor` is null, so the app never asks for an
    /// older page — this is what makes that robust rather than lucky.
    func testMessagingPagesAndPollsStillFindTheirFixtures() {
        for (pathAndQuery, fixture) in [
            (ExchangeAPI.threadsPath(cursor: "opaque-cursor", limit: 50), "exchange-threads"),
            (ExchangeAPI.threadPath(FixtureCatalogue.fixtureThreadID, before: "opaque", limit: 100),
             "exchange-thread"),
        ] {
            let (path, query) = FixtureCatalogue.split(pathAndQuery)
            XCTAssertNotNil(query)
            XCTAssertEqual(FixtureCatalogue.fixtureName(path: path, query: query), fixture)
        }
    }

    /// No messaging WRITE path has a fixture. The protocol refuses every
    /// non-GET before it looks at the table, so this is the second fence, not
    /// the first — but a GET-shaped entry on a write path would be a
    /// fabricated success waiting for a verb change.
    func testNoMessagingWritePathHasAFixture() {
        let thread = FixtureCatalogue.fixtureThreadID
        for pathAndQuery in [
            ExchangeAPI.openThreadPath(listingID: "lst_synthetic_1"),
            ExchangeAPI.messagesPath(threadID: thread),
            ExchangeAPI.readPath(threadID: thread),
            ExchangeAPI.closePath(threadID: thread),
            ExchangeAPI.blockPath(threadID: thread),
            ExchangeAPI.messagePath(messageID: "msg_synthetic_1"),
            ExchangeAPI.threadPath("thr_that_does_not_exist"),
        ] {
            let (path, query) = FixtureCatalogue.split(pathAndQuery)
            XCTAssertNil(FixtureCatalogue.fixtureName(path: path, query: query), pathAndQuery)
        }
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
    private static let decoders: [(String, @Sendable (Data) async throws -> Void)] = [
        ("auth-me", { _ = try await MeAPI.decode(from: $0) }),
        ("journal-list", { _ = try await JournalAPI.decodeList(from: $0) }),
        ("locations-list", { _ = try await LocationsAPI.decodeList(from: $0) }),
        ("locations-parcels", { _ = try await LocationsAPI.decodeParcels(from: $0) }),
        ("items", { _ = try await LocationsAPI.decodeItems(from: $0) }),
        ("units-rate", { _ = try await LocationsAPI.decodeUnits(from: $0) }),
        ("tasks-list", { _ = try await WorkItemAPI.decodeList(from: $0) }),
        ("calculator-sample", { _ = try await CalculatorAPI.decode(from: $0) }),
        ("costs-defaults", { _ = try await APIClient.shared.decode($0, as: OverheadDefaults.self) }),
        ("costs-defaults-crop", { _ = try await APIClient.shared.decode($0, as: CropCostDefaults.self) }),
        ("costs-machinery", { _ = try await APIClient.shared.decode($0, as: MachineryDepreciation.self) }),
        ("exchange-listings", { _ = try await ExchangeAPI.decodeListings(from: $0) }),
        ("exchange-my-listings", { _ = try await ExchangeAPI.decodeMyListings(from: $0) }),
        ("exchange-threads", { _ = try await ExchangeAPI.decodeThreads(from: $0) }),
        ("exchange-thread", { _ = try await ExchangeAPI.decodeThread(from: $0) }),
        ("admin-members", { _ = try await AdminAPI.decodeMembers(from: $0) }),
        ("admin-farm-profile", { _ = try await AdminAPI.decodeFarmProfile(from: $0) }),
        ("insurance-leads", { _ = try await FarmRiskAPI.decodeLeads(from: $0) }),
        ("risk-analysis-holes", { _ = try await FarmRiskAPI.decodeAnalysis(from: $0) }),
        ("risk-analysis-simple", { _ = try await FarmRiskAPI.decodeAnalysis(from: $0) }),
        ("risk-analysis-nogeom", { _ = try await FarmRiskAPI.decodeAnalysis(from: $0) }),
        ("dashboard-ag", { _ = try await DashboardAPI.decodeAg(from: $0) }),
        ("dashboard-task-trend", { _ = try await DashboardAPI.decodeTaskTrend(from: $0) }),
        ("dashboard-field-briefing", { _ = try await DashboardAPI.decodeFieldBriefing(from: $0) }),
        // No named decode function on these two routes: `DashboardStore` and
        // `TrendsStore` call `APIClient.shared.decode(_:as:)` inline, so that
        // is what runs here.
        ("trends-prices", { _ = try await APIClient.shared.decode($0, as: PricesResponse.self) }),
        ("trends-news", { _ = try await APIClient.shared.decode($0, as: NewsResponse.self) }),
        ("trends-news-mine", { _ = try await APIClient.shared.decode($0, as: NewsResponse.self) }),
        ("trends-news-tags", { _ = try await APIClient.shared.decode($0, as: NewsTagCatalogue.self) }),
        ("news-preferences", { _ = try await APIClient.shared.decode($0, as: NewsPreferencesAPI.Body.self) }),
        // agrent-ios#138.
        ("task-detail-fieldop", { _ = try await WorkItemAPI.decodeDetail(from: $0) }),
        ("task-detail-task", { _ = try await WorkItemAPI.decodeDetail(from: $0) }),
        ("task-parcels", { _ = try await WorkItemAPI.decodeParcels(from: $0) }),
        ("field-operation-detail", { _ = try await FieldOperationAPI.decodeDetail(from: $0) }),
        // agrent-ios#179 stage 3.
        ("me-farms", { _ = try await FarmsAPI.decodeFarms(from: $0) }),
        // agrent-ios#258.
        ("admin-price-overrides", { _ = try await APIClient.shared.decode($0, as: AdminPricesAPI.Overrides.self) }),
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
