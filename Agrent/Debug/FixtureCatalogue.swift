#if DEBUG
import Foundation

/// WHICH RECORDED PAYLOAD ANSWERS WHICH REQUEST.
///
/// Pure — a path and a query in, a file name out, no network and no bundle —
/// so the table can be checked by the unit suite rather than by looking at a
/// screenshot and deciding it looks right. `FixtureSeamTests` walks every
/// entry, loads the file it names and decodes it with the SAME function the
/// app calls on that route, so a fixture that would fail to decode on a
/// screen fails in CI instead.
///
/// ── The keys come from the app's own path builders ──
///
/// Not from string literals. `JournalAPI.listPath`, `LocationsAPI.itemsPath`
/// and the rest are the exact strings `APIClient.send` is handed, so a route
/// that moves takes its fixture with it and cannot half-move. The one thing
/// spelled out by hand is the location id inside the parcels path, and
/// `FixtureSeamTests` holds that against `locations-list.json` rather than
/// trusting it.
///
/// ── Two buckets, because the query matters on exactly one route ──
///
/// `/units` and `/units?measure=RATE` are different lists — 4 rate units
/// against 20, and the 20 include `kg`, `ha`, `t` and `%`, none of which is a
/// dose rate (`LocationsAPI.rateUnitsPath`). So a query-sensitive lookup runs
/// first. Everywhere else the query is paging or filtering that a single
/// recorded page cannot honour anyway, and matching on the path alone is what
/// lets one fixture answer `?limit=50` and `?limit=50&cursor=…` alike.
///
/// ── What is deliberately absent ──
///
/// Every write route, and every read this repo has no payload for: the agro
/// tile routes, parcel history, the task detail of every task but the one
/// field operation (#138, below), the insurance catalogue, every Тенденции
/// price other than Табло's wheat, and every news filter other than
/// «Всички». They are answered `501 NO_FIXTURE` by `FixtureURLProtocol` and
/// the screen shows the ordinary server-error state. A screenshot of that is
/// a true report; a fabricated 200 would not be.
///
/// The parcel-line MARK is a write like any other here: 501 `WRITE_REFUSED`.
/// A 5xx reads as the server being unwell, so a tap on «Готово» under the
/// seam would keep the mark on the phone, and every replay would meet the
/// same 501 — nothing leaves the process either way. The harness taps none
/// regardless: a real mark deducts stock and files a ДНЕВНИК row, and the
/// first one is the owner's.
///
/// Табло, Новини, Риск and Админ WERE on that list until agrent-ios#115 put
/// the screenshot harness on this seam. They now have SYNTHETIC payloads —
/// invented, and labelled as invented in `Tests/Fixtures/README.md` — which
/// is a different claim from "recorded": what those four captures evidence
/// is layout, contrast and Dynamic Type over a payload of the right SHAPE,
/// not what the live tenant holds.
enum FixtureCatalogue {
    /// The only location `locations-list.json` contains.
    ///
    /// A request for any other location's parcels is answered `NO_FIXTURE`,
    /// which is the honest answer: in the fixture world that location does
    /// not exist.
    static let fixtureLocationID = "loc_synthetic_1"

    /// The only conversation `exchange-thread.json` holds, and the first row
    /// of `exchange-threads.json`. Any other thread id is `NO_FIXTURE`, for
    /// the reason above.
    ///
    /// Every messaging WRITE — open, send, read, close, block, unblock,
    /// retract — stays absent from this table and is answered 501
    /// `WRITE_REFUSED`. A conversation screen under the seam therefore sees
    /// its automatic mark-read fail, and must swallow that as it would in
    /// production.
    static let fixtureThreadID = "thr_synthetic_1"

    /// The three parcels `locations-parcels.json` holds, each with its own
    /// Риск reading (agrent-ios#115).
    ///
    /// One fixture PER parcel rather than one for all three, because
    /// `FarmRiskStore.readRisks` asks once per row and a shared answer would
    /// photograph three identical chips — which is exactly the screen whose
    /// three levels, the stale-reading caveat and the «Няма отчет» absence
    /// the checklist wants to see side by side. Spelled by hand for the same
    /// reason `fixtureLocationID` is; `FixtureSeamTests` holds them against
    /// the parcels file.
    ///
    /// ── The ids carry `_`, which is what found agrent-ios#122 ──
    ///
    /// `analysisPath` used to escape `_` and `url(for:)` escaped the `%`
    /// again, so the wire carried `par%255Fholes` while `url.path` decoded it
    /// back to the builder's string and this table matched anyway — the seam
    /// could not see the bug it was routing around. `_` now passes through
    /// untouched, and `byPath` keys on the DECODED path (see `decodedPath`),
    /// which is what `FixtureURLProtocol` compares against.
    /// The one FIELD OPERATION the fixtures hold — `tasks-list.json`'s third
    /// row — whose detail and parcel lines are served (agrent-ios#138), so
    /// A11yShots can photograph a task with lines in all three states. Every
    /// other task id but `fixtureTaskID` stays `NO_FIXTURE`. Spelled by hand for the reason
    /// `fixtureLocationID` is; `FixtureSeamTests` holds it against the files.
    static let fixtureFieldOperationTaskID = "tsk_fixture_fieldop"

    /// `tasks-list.json`'s row 1, a plain `TASK` with linked parcels — for
    /// the parcels map every other kind of task has (agrent-ios#177).
    static let fixtureTaskID = "tsk_fixture_2"

    static let fixtureRiskParcels: [(parcelID: String, fixture: String)] = [
        ("par_holes", "risk-analysis-holes"),
        ("par_simple", "risk-analysis-simple"),
        ("par_nogeom", "risk-analysis-nogeom"),
    ]

    /// Routes whose QUERY changes which payload is correct. Consulted first.
    ///
    /// Prices and news joined `units-rate` here for #115, and for its reason:
    /// the query names WHICH commodity and WHICH category. Matched on the path
    /// alone, Тенденции's maize chart would draw the wheat fixture under the
    /// word «Царевица» and Новини's «Политика» filter would show market news
    /// — screenshots that look fine and are wrong. Only the exact request the
    /// captured screens make (Табло's wheat over three months, Новини's
    /// unfiltered first page) is answered; any other is `NO_FIXTURE`.
    static let byPathAndQuery: [String: String] = table([
        (LocationsAPI.rateUnitsPath, "units-rate"),
        (TrendsAPI.pricesPath(.wheat, range: .month3), "trends-prices"),
        (TrendsAPI.newsPath(.all), "trends-news"),
        // agrent-ios#231: the feed for the fixture person's topics, exactly
        // as `NewsStore` asks for it — sorted, no search, first page.
        (TrendsAPI.newsPath(tags: ["subsidies", "wheat"], query: nil, cursor: nil), "trends-news-mine"),
        // agrent-ios#245: «Култура»'s last sheet for the calculator fixture's
        // first crop, as `NewCostView` asks for it. Without the query this is
        // the overhead payload, which is `costs-defaults` on the path alone.
        (CostsAPI.cropDefaultsPath("WHEAT"), "costs-defaults-crop"),
    ]) { $0 }

    /// Routes matched on the path alone.
    static let byPath: [String: String] = table([
        (MeAPI.path, "auth-me"),
        (JournalAPI.listPath, "journal-list"),
        (LocationsAPI.listPath, "locations-list"),
        (LocationsAPI.parcelsPath(fixtureLocationID), "locations-parcels"),
        (LocationsAPI.itemsPath, "items"),
        (WorkItemAPI.listPath, "tasks-list"),
        (CalculatorAPI.path, "calculator-sample"),
        (CostsAPI.defaultsPath, "costs-defaults"),
        (CostsAPI.machineryPath, "costs-machinery"),
        (ExchangeAPI.listingsPath, "exchange-listings"),
        (ExchangeAPI.myListingsPath, "exchange-my-listings"),
        (ExchangeAPI.threadsPath, "exchange-threads"),
        (ExchangeAPI.threadPath(fixtureThreadID), "exchange-thread"),
        // ── Added for agrent-ios#115, so A11yShots can run on the seam ──
        //
        // Every screen the harness photographs from the menu — Риск, Новини,
        // Табло, Админ — used to be `NO_FIXTURE` here, which was right while
        // nothing photographed them under the seam: an error state is a true
        // report. Once the harness moved onto the seam those captures would
        // have been four pictures of «Грешка от сървъра», so each GET they
        // make got a SYNTHETIC payload. Provenance in Tests/Fixtures/README.md.
        //
        // Админ's invites view (`AdminAPI.invitesPath`) is the same PATH as
        // the members list and nothing calls it today; if something starts
        // to, it belongs in `byPathAndQuery` with its own fixture, or it will
        // be answered with the members.
        (AdminAPI.membersPath, "admin-members"),
        (AdminAPI.farmProfilePath, "admin-farm-profile"),
        (FarmRiskAPI.leadsPath, "insurance-leads"),
        (DashboardAPI.agPath, "dashboard-ag"),
        (DashboardAPI.taskTrendPath(days: DashboardAPI.DefaultWindow.tasks), "dashboard-task-trend"),
        (DashboardAPI.fieldBriefingPath, "dashboard-field-briefing"),
        // agrent-ios#138: one field-operation task, its detail and its lines.
        (WorkItemAPI.detailPath(fixtureFieldOperationTaskID), "task-detail-fieldop"),
        (FieldOperationAPI.detailPath(fixtureFieldOperationTaskID), "field-operation-detail"),
        // agrent-ios#177: a plain task, its detail and its parcels.
        (WorkItemAPI.detailPath(fixtureTaskID), "task-detail-task"),
        (WorkItemAPI.parcelsPath(fixtureTaskID), "task-parcels"),
        // agrent-ios#179 stage 3: the person's farms, for Профил's list. A GET
        // only — the POST on the same path is a write, answered 501 as every
        // write is.
        (FarmsAPI.farmsPath, "me-farms"),
        // agrent-ios#231: Новини's tag catalogue and the person's topics.
        // GETs only — choosing a topic is a PUT, answered 501 as every write.
        (TrendsAPI.newsTagsPath, "trends-news-tags"),
        (NewsPreferencesAPI.path, "news-preferences"),
        // agrent-ios#258: the superuser's prices form. The GET only — the
        // day's prices (POST) and a clear (DELETE) are writes to every
        // farm's prices, answered 501 as every write is.
        (AdminPricesAPI.path, "admin-price-overrides"),
    ] + fixtureRiskParcels.map { (FarmRiskAPI.analysisPath($0.parcelID), $0.fixture) }
    ) { decodedPath(split($0).path) }

    /// A builder's path as `url.path` will report it.
    ///
    /// Builders return the PERCENT-ENCODED path (`URLEscape`), and
    /// `FixtureURLProtocol` looks up `url.path`, which is DECODED. For every id
    /// the fixtures use today the two spellings are identical; decoding here
    /// keeps them identical for an id that escapes to something else.
    static func decodedPath(_ path: String) -> String {
        path.removingPercentEncoding ?? path
    }

    /// Every fixture the table can name, for the test that proves each one
    /// exists in the bundle and decodes.
    static var allFixtureNames: [String] {
        (Array(byPathAndQuery.values) + Array(byPath.values)).sorted()
    }

    /// The fixture that answers this request, or nil for "nothing recorded
    /// here".
    static func fixtureName(path: String, query: String?) -> String? {
        let path = inFixtureFarm(path)
        let full = query.map { "\(path)?\($0)" } ?? path
        return byPathAndQuery[full] ?? byPath[path]
    }

    /// A farm path with NO farm in it, read as the fixture world's one farm.
    ///
    /// The tables are static, built on first use from the app's own path
    /// builders — and since #192 a builder with no farm open builds
    /// `/api/t//…` rather than the pinned farm's path (`FarmPath`). Built
    /// before the seam opened its farm, or in a unit test that opens none, a
    /// key would otherwise name no farm. Only the EMPTY farm is read this way:
    /// a path for any other farm stays itself, and is `NO_FIXTURE`.
    static func inFixtureFarm(_ path: String) -> String {
        let unscoped = FarmPath.prefix + "/"
        guard path.hasPrefix(unscoped) else { return path }
        return FarmPath.root(for: Config.pinnedFarmSlug) + "/" + path.dropFirst(unscoped.count)
    }

    /// `"/a/b?c=d"` → `(path: "/a/b", query: "c=d")`.
    ///
    /// The app's path constants carry their query inline, and
    /// `APIClient.url(for:)` splits them exactly this way before sending. The
    /// table has to split them too, or `byPath` would hold a key spelled
    /// `/api/t/agrent/journal?limit=50` that no `url.path` can ever equal.
    static func split(_ pathAndQuery: String) -> (path: String, query: String?) {
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1,
                                       omittingEmptySubsequences: false)
        let query = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (String(parts[0]), query)
    }

    /// Build a dictionary and REFUSE a duplicate key.
    ///
    /// A Swift dictionary literal traps on a duplicate, which would be a
    /// crash on first use with no indication of which two routes collided.
    /// Two paths can genuinely collapse onto one key here — `/units` and
    /// `/units?measure=RATE` differ only in the part `byPath` throws away —
    /// so the collision is a real possibility rather than a theoretical one,
    /// and it is worth a message naming both fixtures.
    private static func table(
        _ entries: [(String, String)], key: (String) -> String
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (pathAndQuery, fixture) in entries {
            let k = inFixtureFarm(key(pathAndQuery))
            if let existing = result[k] {
                preconditionFailure(
                    "Two fixtures claim \(k): \(existing) and \(fixture). "
                    + "If they differ only by query string, the second belongs "
                    + "in byPathAndQuery."
                )
            }
            result[k] = fixture
        }
        return result
    }
}
#endif
