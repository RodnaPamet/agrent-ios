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
/// Every write route, and every read this repo has no recorded payload for:
/// the dashboard, trends, news, admin, farm risk, the agro tile routes and
/// the task detail. They are answered `501 NO_FIXTURE` by
/// `FixtureURLProtocol` and the screen shows the ordinary server-error state.
/// A screenshot of that is a true report; a fabricated 200 would not be.
enum FixtureCatalogue {
    /// The only location `locations-list.json` contains.
    ///
    /// A request for any other location's parcels is answered `NO_FIXTURE`,
    /// which is the honest answer: in the fixture world that location does
    /// not exist.
    static let fixtureLocationID = "loc_synthetic_1"

    /// Routes whose QUERY changes which payload is correct. Consulted first.
    static let byPathAndQuery: [String: String] = table([
        (LocationsAPI.rateUnitsPath, "units-rate"),
    ]) { $0 }

    /// Routes matched on the path alone.
    static let byPath: [String: String] = table([
        (MeAPI.path, "auth-me"),
        (JournalAPI.listPath, "journal-list"),
        (LocationsAPI.listPath, "locations-list"),
        (LocationsAPI.parcelsPath(fixtureLocationID), "locations-parcels"),
        (LocationsAPI.itemsPath, "items"),
        (LocationsAPI.allUnitsPath, "units-all"),
        (WorkItemAPI.listPath, "tasks-list"),
        (CalculatorAPI.path, "calculator-sample"),
        (ExchangeAPI.listingsPath, "exchange-listings"),
        (ExchangeAPI.myListingsPath, "exchange-my-listings"),
    ]) { split($0).path }

    /// Every fixture the table can name, for the test that proves each one
    /// exists in the bundle and decodes.
    static var allFixtureNames: [String] {
        (Array(byPathAndQuery.values) + Array(byPath.values)).sorted()
    }

    /// The fixture that answers this request, or nil for "nothing recorded
    /// here".
    static func fixtureName(path: String, query: String?) -> String? {
        let full = query.map { "\(path)?\($0)" } ?? path
        return byPathAndQuery[full] ?? byPath[path]
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
            let k = key(pathAndQuery)
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
