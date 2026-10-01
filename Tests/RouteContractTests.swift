import XCTest
@testable import Agrent

/// Every path the app builds must be a route agri-saas serves (agrent-ios#132).
///
/// ── The defect this exists for ──
///
/// #130: agri-saas#1087 moved the vegetation tiles from
/// `/agro/<index>-tiles?locationId=` to `/agro/locations/{locationId}/
/// <index>-tiles`. The app kept calling the old shape, it 404'd, `tiles` came
/// back nil, and the overlay silently never mounted until the owner saw it on
/// a phone. Both repos' suites were green: each only checks its own callers,
/// and a rename is invisible from either side alone.
///
/// ── What it checks against ──
///
/// `Tests/Contract/agri-saas-routes.txt`, a SNAPSHOT of agri-saas's own
/// `src/generated/route-inventory.json`, stamped with the agri-saas commit it
/// came from (`scripts/refresh-agri-saas-routes.sh`). A snapshot and not a
/// live fetch: the server changes daily and a fetch would redden unrelated
/// PRs here on the other repo's schedule. Staleness is the scheduled job's
/// problem (`.github/workflows/agri-saas-routes.yml`), not every PR's.
///
/// Four outcomes per app path:
///
///   live, documented    — in openapi.json. Fine.
///   live, undocumented  — real, on agri-saas's undocumented baseline. Fine;
///                         239 of 368 routes are in this state, including
///                         `/api/auth/token/refresh`, which every launch hits.
///   retired             — FAILS, quoting the server's `reason`.
///   absent              — FAILS. The #130 class.
///
/// It checks the PATH, not the method. The inventory carries no methods for
/// undocumented routes, so a method check could cover a third of them at
/// most, and #130 was a path defect.
///
/// ── How "every path the app builds" is made honest ──
///
/// The list below calls each builder by hand, so it can fall behind the app.
/// Two source scans fail when it does: every path-shaped string literal under
/// `Agrent/` must be produced by some listed builder in the same file
/// (`testEveryPathLiteralIsCoveredByTheEnumeration`), and every `…Path`
/// builder must be named here (`testEveryPathBuilderIsEnumerated`). Fully
/// literal paths (`AuthClient`'s, `APIClient`'s refresh) need no builder and
/// are checked straight from the source.
final class RouteContractTests: XCTestCase {

    // MARK: - Fixtures

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// NextAuth endpoints the app calls, if it ever does.
    ///
    /// `/api/auth/[...nextauth]` is a catch-all, EXCLUDED from agri-saas's
    /// inventory on purpose — listing it would make every `/api/auth/<typo>`
    /// look served. So a NextAuth path the app calls on purpose goes here,
    /// by name, with a line saying why. Empty today: sign-in is the native
    /// flow (`/api/auth/native/*`, `/api/auth/token/refresh`), which are
    /// ordinary routes and in the inventory.
    private static let nextAuthAllowlist: Set<String> = []

    /// Files whose `/x` literals are not API paths at all.
    private static let notAPIPaths: [String: String] = [
        // The web app's page routes the bottom tabs map onto, compared with
        // `/api/account/bottom-tabs` values. Never requested.
        "AppSurface.swift": "web page routes, not API paths",
    ]

    // MARK: - Every path the app builds
    //
    // Ids are their own TEMPLATE NAMES in braces. `URLEscape.segment` escapes
    // the braces and `template(_:)` decodes them back, so a built path reads
    // `/api/t/{tenantSlug}/locations/{locationId}/parcels` — the spec's form,
    // with this app's parameter names. Query values are arbitrary; the query
    // is stripped before matching, as the server's router ignores it.

    private struct Built {
        let file: String
        let path: String
    }

    private static let built: [Built] = {
        let loc = "{locationId}", parcel = "{parcelId}", id = "{id}"
        var all: [(String, [String])] = [
            ("CurrentUser.swift", [MeAPI.path]),
            ("BottomTabsStore.swift", [BottomTabsAPI.path]),
            ("JournalAPI.swift", [JournalAPI.listPath, JournalAPI.path(cursor: "c")]),
            ("ExchangeAPI.swift", [
                ExchangeAPI.listingsPath,
                ExchangeAPI.listingsPath(ExchangeQuery(text: "q", minTonnes: 1, maxTonnes: 2, cursor: "c")),
                ExchangeAPI.myListingsPath,
                ExchangeAPI.inquiriesPath,
                ExchangeAPI.listingPath("{listingId}"),
                ExchangeAPI.threadsPath,
                ExchangeAPI.threadsPath(cursor: "c", limit: 10),
                ExchangeAPI.threadPath("{threadId}"),
                ExchangeAPI.threadPath("{threadId}", before: "b", limit: 10),
                ExchangeAPI.openThreadPath(listingID: "{listingId}"),
                ExchangeAPI.messagesPath(threadID: "{threadId}"),
                ExchangeAPI.readPath(threadID: "{threadId}"),
                ExchangeAPI.closePath(threadID: "{threadId}"),
                ExchangeAPI.blockPath(threadID: "{threadId}"),
                ExchangeAPI.messagePath(messageID: "{messageId}"),
            ]),
            ("LocationsAPI.swift", [
                LocationsAPI.listPath,
                LocationsAPI.parcelsPath(loc),
                LocationsAPI.itemsPath,
                LocationsAPI.rateUnitsPath,
                LocationsAPI.allUnitsPath,
                LocationsAPI.operationsPath(loc),
                LocationsAPI.parcelPath(locationID: loc, parcelID: parcel),
            ]),
            ("WorkItemAPI.swift", [
                WorkItemAPI.listPath, WorkItemAPI.detailPath(id), WorkItemAPI.statusPath(id),
            ]),
            ("AdminAPI.swift", [
                AdminAPI.membersPath, AdminAPI.invitesPath, AdminAPI.farmProfilePath,
                AdminAPI.invitePath,
                AdminAPI.deactivatePath("{membershipId}"),
                AdminAPI.reactivatePath("{membershipId}"),
            ]),
            ("DashboardAPI.swift", [
                DashboardAPI.agPath, DashboardAPI.taskTrendPath(),
                DashboardAPI.taskTrendPath(days: 14), DashboardAPI.fieldBriefingPath,
            ]),
            ("CalculatorAPI.swift", [CalculatorAPI.path, CostsAPI.listPath]),
            ("ParcelHistoryAPI.swift", [
                ParcelHistoryAPI.cropSeasonsPath(parcel),
                ParcelHistoryAPI.weedObservationsPath(parcel),
                ParcelHistoryAPI.cropSeasonPath(parcelID: parcel, seasonID: "{seasonId}"),
                ParcelHistoryAPI.weedObservationPath(parcelID: parcel, observationID: "{observationId}"),
                ParcelHistoryAPI.historyPath(parcelID: parcel),
                ParcelHistoryAPI.historyPath(parcelID: parcel, limit: 5, seasonsBefore: "s"),
            ]),
            ("SpatialImportAPI.swift", [
                SpatialImportAPI.uploadPath(locationID: loc),
                SpatialImportAPI.jobPath(locationID: loc, jobID: "{jobId}"),
            ]),
            ("FarmRiskModels.swift", [FarmRiskAPI.analysisPath(parcel), FarmRiskAPI.leadsPath]),
            ("InsuranceCatalogue.swift", [InsuranceCatalogueAPI.path]),
            ("NewsModels.swift",
             PriceRange.allCases.map { TrendsAPI.pricesPath(.wheat, range: $0) }
                + NewsCategory.allCases.map { TrendsAPI.newsPath($0) }),
        ]
        // Every index, because the index is a LITERAL segment (`ndvi-tiles`),
        // not a parameter: a server that dropped one would 404 that one only.
        all.append(("VegetationIndex.swift",
                    VegetationIndex.allCases.map { AgroAPI.path($0, locationID: loc) }))
        return all.flatMap { file, paths in paths.map { Built(file: file, path: $0) } }
    }()

    // MARK: - The checks

    /// THE GUARD. Every app path is live on the server, or the test names it.
    func testEveryPathTheAppBuildsIsServed() throws {
        let inventory = try Inventory.load()
        print("agri-saas routes snapshot from \(inventory.sha)")

        var counts = [String: Int]()
        var failures: [String] = []
        for (template, origin) in try Self.appTemplates().sorted(by: { $0.key < $1.key }) {
            let (outcome, failure) = Self.classify(template, in: inventory)
            if let failure { failures.append("\(failure)  [built in \(origin)]") }
            counts[outcome, default: 0] += 1
            print("  \(outcome.padding(toLength: 22, withPad: " ", startingAt: 0)) \(template)")
        }
        print("  " + counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            .joined(separator: ", "))

        XCTAssertGreaterThan(counts.values.reduce(0, +), 40,
                             "positive control: the enumeration collapsed")
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) path(s) the app builds are not live on agri-saas "
                      + "(snapshot \(inventory.sha)):\n" + failures.joined(separator: "\n"))
    }

    /// The four outcomes, and the failure text each one prints.
    private static func classify(_ template: String, in inventory: Inventory) -> (String, String?) {
        if nextAuthAllowlist.contains(template) { return ("nextauth (allowlisted)", nil) }
        guard let route = inventory.route(matching: template) else {
            return ("ABSENT", "ABSENT   \(template) — agri-saas \(inventory.sha.prefix(12)) "
                    + "serves no route of this shape")
        }
        switch (route.live, route.documented) {
        case (true, true): return ("live, documented", nil)
        case (true, false): return ("live, undocumented", nil)
        case (false, _):
            return ("RETIRED", "RETIRED  \(template) — agri-saas retired \(route.path): "
                    + (route.reason ?? "no reason given"))
        }
    }

    /// Retired fails and quotes the server's reason; a live route of the same
    /// shape outranks it; an unknown shape is absent.
    func testTheOutcomesOnAKnownInventory() throws {
        let inv = try Inventory.parse("""
        # sha 0123
        retired documented   /api/t/{tenantSlug}/agro/ndvi-tiles moved under /agro/locations (#1087)
        live    undocumented /api/t/{tenantSlug}/admin/members
        retired undocumented /api/t/{tenantSlug}/things/{id}
        live    documented   /api/t/{tenantSlug}/things/{thingId}
        """)
        XCTAssertEqual(inv.sha, "0123")
        let retired = Self.classify("/api/t/{tenantSlug}/agro/ndvi-tiles", in: inv)
        XCTAssertEqual(retired.0, "RETIRED")
        XCTAssertTrue(retired.1?.contains("moved under /agro/locations (#1087)") == true,
                      "the server's reason is quoted: \(retired.1 ?? "nil")")
        XCTAssertEqual(Self.classify("/api/t/{tenantSlug}/admin/members", in: inv).0,
                       "live, undocumented")
        XCTAssertEqual(Self.classify("/api/t/{tenantSlug}/things/{x}", in: inv).0,
                       "live, documented")
        XCTAssertEqual(Self.classify("/api/t/{tenantSlug}/nope", in: inv).0, "ABSENT")
        XCTAssertThrowsError(try Inventory.parse("gone documented /api/x"))
    }

    /// The #130 path itself, pinned. If this ever matches, the matcher has
    /// gone loose enough to have missed the defect it exists for.
    func testTheOldTilesRouteIsNotAccepted() throws {
        let inventory = try Inventory.load()
        let old = Self.template("/api/t/\(Config.tenantSlug)/agro/ndvi-tiles?locationId=x")
        XCTAssertEqual(old, "/api/t/{tenantSlug}/agro/ndvi-tiles")
        XCTAssertNil(inventory.route(matching: old), "#130's route reads as served")
        XCTAssertNotNil(inventory.route(matching: Self.template(
            AgroAPI.path(.ndvi, locationID: "{locationId}"))), "positive control")
    }

    /// The spec spells parameters its own way (`{id}`, `{parcelId}`), this app
    /// spells them its own way. Matching is by SEGMENT SHAPE: a `{…}` segment
    /// matches any `{…}` segment, a literal matches only itself.
    func testParameterNamesDoNotHaveToAgree() {
        let inv = Inventory(sha: "x", routes: [
            Inventory.Route(path: "/api/t/{tenantSlug}/tasks/{id}/status", live: true,
                            documented: true, reason: nil),
        ])
        XCTAssertNotNil(inv.route(matching: "/api/t/{tenantSlug}/tasks/{taskId}/status"))
        XCTAssertNil(inv.route(matching: "/api/t/{tenantSlug}/tasks/status/{taskId}"))
        XCTAssertNil(inv.route(matching: "/api/t/{tenantSlug}/tasks/{taskId}"))
        // A literal segment never matches a parameter: `/agro/ndvi-tiles`
        // must not be read as served by some `/agro/{x}`.
        let loose = Inventory(sha: "x", routes: [
            Inventory.Route(path: "/api/t/{tenantSlug}/agro/{x}", live: true,
                            documented: true, reason: nil),
        ])
        XCTAssertNil(loose.route(matching: "/api/t/{tenantSlug}/agro/ndvi-tiles"))
    }

    /// The list the scheduled job intersects with removed server paths. It
    /// runs on Linux and cannot run this suite, so the app's templates are
    /// written down — and held exact here, so the file cannot rot.
    func testTheAppRoutesFileIsCurrent() throws {
        let expected = try Self.appTemplates().keys.sorted().joined(separator: "\n") + "\n"
        let committed = try Self.read("Tests/Contract/app-routes.txt")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n") + "\n"
        XCTAssertEqual(committed, expected,
                       "Tests/Contract/app-routes.txt is out of date. Its non-comment lines "
                       + "must be exactly:\n" + expected)
    }

    // MARK: - Completeness

    /// Every path-shaped literal in the app is produced by a builder listed
    /// above, in the same file — or it is fully literal and checked as is.
    ///
    /// "Path-shaped": starts `/api/`; or starts with an interpolation followed
    /// by `/word` or `/\(…)` (`"\(base)/listings"`); or starts `/word` (a
    /// fragment, `base + "/x"`). Adjacent literals joined by `+` are read as
    /// one, as `AgroAPI.path` is written across two lines.
    func testEveryPathLiteralIsCoveredByTheEnumeration() throws {
        var uncovered: [String] = []
        var seen = 0
        for file in try Self.appSources() {
            let source = try Self.read(file)
            let name = (file as NSString).lastPathComponent
            let literals = PathLiteralScanner.literals(in: source)
            let base = literals.first { $0.lineText.contains("static var base: String") }
            let built = Self.built.filter { $0.file == name }.map { Self.template($0.path) }
            for literal in literals {
                guard let kind = PathLiteralScanner.kind(literal.parts) else { continue }
                // A file's `base` is a PREFIX, never requested as written; it
                // is spliced into each `\(base)/…` literal and checked there.
                if let base, literal.line == base.line { continue }
                if kind == .fragment, Self.notAPIPaths[name] != nil { continue }
                seen += 1
                if !literal.hasInterpolation, kind == .anchored { continue }  // checked as is
                let pattern = PathLiteralScanner.pattern(literal.parts, kind: kind, base: base?.parts)
                let regex = try NSRegularExpression(pattern: pattern)
                let hit = built.contains {
                    regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }
                if !hit {
                    uncovered.append("\(file):\(literal.line)  \(literal.rendered)")
                }
            }
        }
        XCTAssertGreaterThan(seen, 50, "positive control: the scanner stopped finding paths")
        XCTAssertTrue(uncovered.isEmpty,
                      "These path literals are not produced by any builder listed in "
                      + "RouteContractTests.built for their file, so the route guard never "
                      + "checks them. Add the builder call there:\n" + uncovered.joined(separator: "\n"))
    }

    /// Every `static … somethingPath` / `path` builder outside `Agrent/Debug`
    /// is called in `built`. Catches a builder made only of other builders
    /// and no literal, which the literal scan cannot see.
    func testEveryPathBuilderIsEnumerated() throws {
        let me = try Self.read("Tests/RouteContractTests.swift")
        let decl = try NSRegularExpression(
            pattern: #"^\s*static (?:func|var|let) (path|\w+Path)\b"#)
        let typeDecl = try NSRegularExpression(
            pattern: #"^(?:final )?(?:enum|struct|class|extension) (\w+)"#)
        var missing: [String] = []
        var found = 0
        for file in try Self.appSources() where !file.hasPrefix("Agrent/Debug/") {
            var owner = ""
            for line in try Self.read(file).components(separatedBy: "\n") {
                let r = NSRange(line.startIndex..., in: line)
                if let m = typeDecl.firstMatch(in: line, range: r) {
                    owner = String(line[Range(m.range(at: 1), in: line)!])
                }
                guard let m = decl.firstMatch(in: line, range: r) else { continue }
                found += 1
                let name = "\(owner).\(line[Range(m.range(at: 1), in: line)!])"
                if !me.contains(name) { missing.append("\(name)  (\(file))") }
            }
        }
        XCTAssertGreaterThan(found, 40, "positive control: no builders found")
        XCTAssertTrue(missing.isEmpty,
                      "Path builders not called in RouteContractTests.built:\n"
                      + missing.joined(separator: "\n"))
    }

    /// The scanner on a known input, so a scanner regression shows here and
    /// not as a silently smaller scan.
    func testTheScannerReadsWhatItClaimsTo() {
        let src = """
        // "/api/in/a/comment"
        /* "/api/in/a/block" */
        let a = "/api/one"
        let b = "/api/t/\\(Config.tenantSlug)/x/"
            + "\\(URLEscape.segment(id))/y"
        let c = "\\(base)/members/\\(seg(f("q")))/z?k=\\(v)"
        let d = "\\(n) of \\(m)"
        """
        let found = PathLiteralScanner.literals(in: src).filter { PathLiteralScanner.kind($0.parts) != nil }
        XCTAssertEqual(found.map(\.rendered), [
            "/api/one",
            "/api/t/\\(Config.tenantSlug)/x/\\(URLEscape.segment(id))/y",
            "\\(base)/members/\\(seg(f(\"q\")))/z?k=\\(v)",
        ])
        XCTAssertEqual(found.map(\.line), [3, 4, 6])
    }

    // MARK: - Helpers

    /// Every app template → where it was first seen. Builders, plus fully
    /// literal `/api/` strings from source (`AuthClient` has no builder).
    private static func appTemplates() throws -> [String: String] {
        var out: [String: String] = [:]
        for b in built { out[template(b.path)] = out[template(b.path)] ?? b.file }
        for file in try appSources() {
            for literal in PathLiteralScanner.literals(in: try read(file))
            where !literal.hasInterpolation && PathLiteralScanner.kind(literal.parts) == .anchored {
                let t = template(literal.rendered)
                out[t] = out[t] ?? "\(file):\(literal.line)"
            }
        }
        return out
    }

    /// A built path in template form: query dropped, ids decoded back to their
    /// `{name}` placeholders, the tenant slug turned back into `{tenantSlug}`.
    static func template(_ pathAndQuery: String) -> String {
        let path = String(pathAndQuery.split(separator: "?", maxSplits: 1,
                                             omittingEmptySubsequences: false)[0])
        var segments = (path.removingPercentEncoding ?? path)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.count > 3, segments[1] == "api", segments[2] == "t",
           segments[3] == Config.tenantSlug {
            segments[3] = "{tenantSlug}"
        }
        return segments.joined(separator: "/")
    }

    private static func appSources() throws -> [String] {
        let dir = root.appendingPathComponent("Agrent")
        guard let walk = FileManager.default.enumerator(atPath: dir.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return walk.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
            .map { "Agrent/\($0)" }.sorted()
    }
}

// MARK: - The snapshot

/// `Tests/Contract/agri-saas-routes.txt`, parsed. Read through `#filePath`
/// rather than bundled: it is a test input, and nothing under `Tests/Contract`
/// may reach the app (only `Tests/Fixtures` is an app resource, Debug only).
private struct Inventory {
    struct Route {
        let path: String
        let live: Bool
        let documented: Bool
        let reason: String?
    }

    let sha: String
    let routes: [Route]

    static func load() throws -> Inventory {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Contract/agri-saas-routes.txt")
        let inventory = try parse(String(contentsOf: url, encoding: .utf8))
        // A truncated or reformatted snapshot must not pass as "nothing is
        // served" (every path ABSENT) — or worse, as a partial list.
        guard inventory.sha.count == 40, inventory.routes.count > 300 else {
            throw CocoaError(.fileReadCorruptFile,
                             userInfo: [NSDebugDescriptionErrorKey: "snapshot header or size is wrong"])
        }
        return inventory
    }

    /// `<live|retired> <documented|undocumented> <path>[ <reason>]`, `#` lines
    /// are comments, `# sha <sha>` is the stamp.
    static func parse(_ text: String) throws -> Inventory {
        var sha = "", routes: [Route] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# sha ") { sha = String(line.dropFirst(6)) }
            if line.hasPrefix("#") { continue }
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, ["live", "retired"].contains(f[0]),
                  ["documented", "undocumented"].contains(f[1]) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: String(line)])
            }
            let rest = f[2].split(separator: " ", maxSplits: 1)
            routes.append(Route(path: String(rest[0]), live: f[0] == "live",
                                documented: f[1] == "documented",
                                reason: rest.count > 1 ? String(rest[1]) : nil))
        }
        return Inventory(sha: sha, routes: routes)
    }

    /// Every `{…}` segment is the same shape, whatever it is called.
    static func shape(_ template: String) -> String {
        template.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("{") && $0.hasSuffix("}") ? "{}" : String($0) }
            .joined(separator: "/")
    }

    /// Live wins over retired: a server-side rename of a PARAMETER retires
    /// `/x/{id}` and adds `/x/{xId}` — one shape, and nothing broke.
    func route(matching template: String) -> Route? {
        let s = Self.shape(template)
        let hits = routes.filter { Self.shape($0.path) == s }
        return hits.first(where: \.live) ?? hits.first
    }
}

// MARK: - The source scan

/// Swift string literals out of source text, enough of the grammar to find
/// paths: skips `//` and `/* */` comments, multi-line `"""` and raw `#"…"#`
/// strings (no path is written that way), keeps `\(…)` interpolations whole
/// (nested parens and quotes included), and joins `"a" + "b"` across lines.
private enum PathLiteralScanner {
    enum Part: Equatable {
        case text(String)
        case interpolation(String)
    }

    struct Literal {
        let line: Int
        let parts: [Part]
        let lineText: String

        var hasInterpolation: Bool {
            parts.contains { if case .interpolation = $0 { return true } else { return false } }
        }

        var rendered: String {
            parts.map {
                switch $0 {
                case .text(let t): t
                case .interpolation(let e): "\\(\(e))"
                }
            }.joined()
        }
    }

    enum Kind { case anchored, leadingInterpolation, fragment }

    static func kind(_ parts: [Part]) -> Kind? {
        guard let first = parts.first else { return nil }
        let startsWord: (Substring) -> Bool = { $0.first.map { $0.isLowercase && $0.isASCII } ?? false }
        switch first {
        case .text(let t):
            if t.hasPrefix("/api/") { return .anchored }
            return t.hasPrefix("/") && startsWord(t.dropFirst()) ? .fragment : nil
        case .interpolation:
            guard parts.count > 1, case .text(let t) = parts[1], t.hasPrefix("/") else { return nil }
            let rest = t.dropFirst()
            return startsWord(rest) || (rest.isEmpty && parts.count > 2) ? .leadingInterpolation : nil
        }
    }

    /// A regex the TEMPLATE of the built path must match. `\(base)` is
    /// replaced by the file's own `base`, so most patterns are anchored at
    /// `/api/`. Any other interpolation: `.+` when it leads (an unknown
    /// prefix such as `\(threadPath(id))`), otherwise one segment.
    static func pattern(_ parts: [Part], kind: Kind, base: [Part]?) -> String {
        var expanded: [Part] = []
        for part in parts {
            if case .interpolation(let e) = part, e == "base" || e == "Self.base", let base {
                expanded += base
            } else {
                expanded.append(part)
            }
        }
        var p = ""
        loop: for (i, part) in expanded.enumerated() {
            switch part {
            case .text(let t):
                if let q = t.firstIndex(of: "?") {
                    p += NSRegularExpression.escapedPattern(for: String(t[..<q]))
                    break loop
                }
                p += NSRegularExpression.escapedPattern(for: t)
            case .interpolation:
                p += i == 0 ? ".+" : "[^/?]+"
            }
        }
        return (kind == .fragment ? "^.*" : "^") + p + "$"
    }

    static func literals(in source: String) -> [Literal] {
        let c = Array(source.unicodeScalars)
        let lines = source.components(separatedBy: "\n")
        var i = 0, line = 1
        var out: [Literal] = []

        func at(_ k: Int) -> Unicode.Scalar? { i + k < c.count ? c[i + k] : nil }
        func isTripleQuote() -> Bool { at(0) == "\"" && at(1) == "\"" && at(2) == "\"" }
        func advance() { if c[i] == "\n" { line += 1 }; i += 1 }

        /// `c[i]` is the opening quote. Appends parts; false if unterminated.
        func readLiteral(into parts: inout [Part]) -> Bool {
            i += 1
            var text = ""
            while i < c.count {
                let ch = c[i]
                if ch == "\n" { return false }
                if ch == "\"" {
                    i += 1
                    if !text.isEmpty { parts.append(.text(text)) }
                    return true
                }
                if ch == "\\", at(1) == "(" {
                    if !text.isEmpty { parts.append(.text(text)); text = "" }
                    i += 2
                    var depth = 1, expr = ""
                    while i < c.count {
                        let x = c[i]
                        if x == "\"" {           // a string inside the interpolation
                            expr.unicodeScalars.append(x); i += 1
                            while i < c.count, c[i] != "\"", c[i] != "\n" {
                                if c[i] == "\\" { expr.unicodeScalars.append(c[i]); i += 1 }
                                if i < c.count { expr.unicodeScalars.append(c[i]); i += 1 }
                            }
                            if i < c.count { expr.unicodeScalars.append(c[i]); i += 1 }
                            continue
                        }
                        if x == "(" { depth += 1 }
                        if x == ")" { depth -= 1; if depth == 0 { i += 1; break } }
                        expr.unicodeScalars.append(x); i += 1
                    }
                    parts.append(.interpolation(expr))
                    continue
                }
                if ch == "\\", let next = at(1) {
                    text.unicodeScalars.append(next == "n" ? "\n" : next == "t" ? "\t" : next)
                    i += 2
                    continue
                }
                text.unicodeScalars.append(ch); i += 1
            }
            return false
        }

        while i < c.count {
            if at(0) == "/", at(1) == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            }
            if at(0) == "/", at(1) == "*" {
                i += 2
                while i < c.count, !(at(0) == "*" && at(1) == "/") { advance() }
                i += 2
                continue
            }
            if isTripleQuote() {
                i += 3
                while i < c.count, !isTripleQuote() { advance() }
                i += 3
                continue
            }
            if at(0) == "#", at(1) == "\"" {
                i += 2
                while i < c.count, !(at(0) == "\"" && at(1) == "#") { advance() }
                i += 2
                continue
            }
            if at(0) == "\"" {
                let start = line
                var parts: [Part] = []
                guard readLiteral(into: &parts) else { continue }
                // `"a"\n    + "b"`: one path written on two lines.
                while true {
                    var j = i, newlines = 0
                    while j < c.count, c[j] == " " || c[j] == "\n" || c[j] == "\t" {
                        if c[j] == "\n" { newlines += 1 }; j += 1
                    }
                    guard j < c.count, c[j] == "+" else { break }
                    j += 1
                    while j < c.count, c[j] == " " || c[j] == "\n" || c[j] == "\t" {
                        if c[j] == "\n" { newlines += 1 }; j += 1
                    }
                    guard j < c.count, c[j] == "\"",
                          !(j + 2 < c.count && c[j + 1] == "\"" && c[j + 2] == "\"") else { break }
                    i = j; line += newlines
                    guard readLiteral(into: &parts) else { break }
                }
                // Merge adjacent text runs from the join.
                var merged: [Part] = []
                for part in parts {
                    if case .text(let b) = part, case .text(let a)? = merged.last {
                        merged[merged.count - 1] = .text(a + b)
                    } else {
                        merged.append(part)
                    }
                }
                out.append(Literal(line: start, parts: merged,
                                   lineText: start <= lines.count ? lines[start - 1] : ""))
                continue
            }
            advance()
        }
        return out
    }
}
