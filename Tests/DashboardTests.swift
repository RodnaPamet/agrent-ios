import XCTest
@testable import Agrent

/// The four dashboard routes, tested against the shapes in the GENERATED spec
/// (`fbb25ab29`) rather than against a description of them.
final class DashboardTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type) async throws -> T {
        try await APIClient.shared.decode(Data(json.utf8), as: type)
    }

    // MARK: - The nullability that is on the TARGET schema

    /// `achievements` is in `required`, and `AgDashboardAchievements` is
    /// `{type: ["object","null"]}` — so the KEY is always present and the
    /// VALUE may be null. Declared non-optional, this null would have failed
    /// the whole dashboard payload.
    ///
    /// I read this idiom wrong once and reported it to the server session as
    /// a contract defect. It is not one: `$ref` to a schema whose own type
    /// admits null admits null. The rule is to check the target, not only the
    /// reference site.
    func testANullAchievementsBlockDoesNotFailTheDashboard() async throws {
        let payload = try await decode(#"""
        {"enabledModules":["agro"],"recentJournal":[],"lowStock":[],
         "myTasks":[],"achievements":null}
        """#, as: AgDashboard.self)
        XCTAssertNil(payload.achievements)
        XCTAssertTrue(payload.isEnabled("agro"))
    }

    // MARK: - enabledModules: absence is the signal

    /// A disabled module is simply not in the array, so a gated tenant gets
    /// empty SECTIONS rather than missing keys — and "empty because gated"
    /// versus "empty because nothing recorded" is decidable only here.
    func testAGatedModuleIsAbsentRatherThanFlaggedFalse() async throws {
        let payload = try await decode(#"""
        {"enabledModules":["agro","grain"],"recentJournal":[],"lowStock":[],
         "myTasks":[],"achievements":null}
        """#, as: AgDashboard.self)

        XCTAssertTrue(payload.isEnabled("grain"))
        XCTAssertFalse(payload.isEnabled("inventory"),
                       "absent means the farm does not have it")
        // The spelling is unverifiable from here — no enum on `items` — so
        // matching is case-insensitive rather than exact.
        XCTAssertTrue(payload.isEnabled("AGRO"))
    }

    // MARK: - The dashboard's own rows

    private static let fullAg = #"""
    {"enabledModules":["agro"],
     "recentJournal":[{"id":"j1","type":"HARVEST","title":"Жътва",
                       "occurredAt":"2026-07-02T09:00:00.000Z"}],
     "lowStock":[{"id":"s1","name":"Раундъп","quantityOnHand":1.15,"unitSymbol":"л"}],
     "myTasks":[{"id":"t1","title":"Пръскане","status":"OPEN","dueAt":null}],
     "achievements":{"milestones":[{"key":"first-harvest","earned":true,
                                    "earnedAt":"2026-07-02T09:00:00.000Z"},
                                   {"key":"season-closed","earned":false,"earnedAt":null}],
                     "streak":{"current":4,"best":11}}}
    """#

    func testTheWholeDashboardDecodes() async throws {
        let d = try await decode(Self.fullAg, as: AgDashboard.self)
        XCTAssertEqual(d.recentJournal.first?.type, .harvest)
        XCTAssertEqual(d.myTasks.first?.status, .open)
        XCTAssertNil(d.myTasks.first?.dueAt)
        XCTAssertEqual(d.achievements?.streak.best, 11)
        XCTAssertEqual(d.achievements?.milestones.count, 2)
    }

    /// `quantityOnHand` is `type: number`, and `WireDecimal` takes the number
    /// branch straight to `Decimal` without going through `Double`. This is a
    /// quantity a farmer reorders against.
    /// 1,15 AND NOT 12,5. The first version of this test used 12.5, which is
    /// 25/2 and therefore exact in binary floating point — so it would have
    /// passed just as well through a `Double` and proved nothing about the one
    /// thing it exists to prove. 1.15 is not representable, so this fails if
    /// the value ever goes via `Double`.
    func testAStockQuantityKeepsItsDigits() async throws {
        let d = try await decode(Self.fullAg, as: AgDashboard.self)
        XCTAssertEqual(d.lowStock.first?.quantityOnHand.value, Decimal(string: "1.15"))
        XCTAssertEqual(d.lowStock.first?.quantityText, "1,15 л")
    }

    /// AND a value `Double` could not hold.
    ///
    /// The previous attempt at this asserted `value != Decimal(1.15)`, which
    /// fails — `Decimal(_: Double)` rounds to the same decimal, so the
    /// assertion could not distinguish the two paths it was written to
    /// distinguish. Nineteen significant digits can: a `Double` carries about
    /// fifteen to seventeen, so the trailing .5 would be gone.
    func testAQuantityWiderThanADoubleSurvives() async throws {
        let json = Self.fullAg.replacingOccurrences(
            of: #""quantityOnHand":1.15"#, with: #""quantityOnHand":123456789012345678.5"#)
        let d = try await decode(json, as: AgDashboard.self)
        XCTAssertEqual(d.lowStock.first?.quantityOnHand.value,
                       Decimal(string: "123456789012345678.5"))
    }

    /// `unitSymbol` is NOT one of the `?? ''` collapses — the relation is
    /// required and the projection reads it straight through, traced in source.
    /// So it is a plain `String`, and this test is about the RENDERING rather
    /// than about the field's type: a blank one still must not leave a
    /// separator hanging off the number, because that costs nothing to prevent
    /// and was the exact shape of two shipped defects.
    func testABlankUnitStillLeavesNoTrailingSeparator() async throws {
        let json = Self.fullAg.replacingOccurrences(of: #""unitSymbol":"л""#,
                                                    with: #""unitSymbol":"""#)
        let d = try await decode(json, as: AgDashboard.self)
        XCTAssertEqual(d.lowStock.first?.unitSymbol, "")
        XCTAssertEqual(d.lowStock.first?.quantityText, "1,15")
        XCTAssertFalse(d.lowStock.first?.quantityText.hasSuffix(" ") ?? true)
    }

    /// One unrecognised journal kind or task status must not cost the whole
    /// dashboard. Both reuse the app's existing `LenientDecodable` enums
    /// rather than a second copy of those vocabularies.
    func testAnUnknownJournalKindAndStatusDoNotFailThePayload() async throws {
        let json = Self.fullAg
            .replacingOccurrences(of: #""HARVEST""#, with: #""BIOCONTROL""#)
            .replacingOccurrences(of: #""OPEN""#, with: #""ESCALATED""#)
        let d = try await decode(json, as: AgDashboard.self)
        XCTAssertEqual(d.recentJournal.first?.type, .unknown)
        XCTAssertEqual(d.myTasks.first?.status, .unknown)
    }

    // MARK: - Milestones

    /// `earnedAt` is null EXACTLY when `earned` is false, and the flag is the
    /// contract while the null is a consequence — same reading as the exchange
    /// tombstone, where `deleted` decides and `body == nil` follows.
    func testAnUnearnedMilestoneCarriesNoDate() async throws {
        let d = try await decode(Self.fullAg, as: AgDashboard.self)
        let unearned = try XCTUnwrap(d.achievements?.milestones.last)
        XCTAssertFalse(unearned.earned)
        XCTAssertNil(unearned.earnedAt)

        let earned = try XCTUnwrap(d.achievements?.milestones.first)
        XCTAssertTrue(earned.earned)
        XCTAssertNotNil(earned.earnedAt)
    }

    /// The milestone keys ARE pinned by the spec — eight of them, in an enum
    /// on the schema — unlike the weed catalogue, which is named only in a
    /// description. A ninth added server-side still must not vanish: a farmer
    /// who earned something should not see a gap.
    func testAMilestoneThisBuildDoesNotKnowIsStillShown() async throws {
        let json = Self.fullAg.replacingOccurrences(of: #""first-harvest""#,
                                                    with: #""first-drone-flight""#)
        let d = try await decode(json, as: AgDashboard.self)
        XCTAssertEqual(d.achievements?.milestones.first?.key, .unknown)
        XCTAssertFalse(d.achievements?.milestones.first?.key.label.isEmpty ?? true)
    }

    /// TWO server-added milestones must be TWO rows.
    ///
    /// `LenientDecodable` discards the wire value, so `key.rawValue` is the
    /// literal "UNKNOWN" for every one of them. Keying `Identifiable` off that
    /// gave them one shared id, and a SwiftUI `ForEach` silently drops all but
    /// the first — so the comment promising "a farmer who earned something
    /// should not see a gap" was producing exactly that gap. The original test
    /// injected ONE unknown key, which is why it could not fail.
    func testTwoUnknownMilestonesRemainTwoDistinctRows() async throws {
        let d = try await decode(#"""
        {"enabledModules":[],"recentJournal":[],"lowStock":[],"myTasks":[],
         "achievements":{"milestones":[
            {"key":"first-drone-flight","earned":true,"earnedAt":"2026-09-01T09:00:00.000Z"},
            {"key":"first-soil-scan","earned":true,"earnedAt":"2026-09-02T09:00:00.000Z"}],
          "streak":{"current":1,"best":1}}}
        """#, as: AgDashboard.self)

        let milestones = try XCTUnwrap(d.achievements?.milestones)
        XCTAssertEqual(milestones.count, 2)
        XCTAssertEqual(Set(milestones.map(\.id)).count, 2, "two rows, not one")
        XCTAssertEqual(milestones.map(\.key), [.unknown, .unknown])

        // And each is NAMED by what the server sent rather than by a shared
        // placeholder — same rule as an unmapped weed showing its binomial.
        XCTAssertEqual(milestones.first?.label, "first-drone-flight")
        XCTAssertNotEqual(milestones.first?.label, milestones.last?.label)
    }

    /// A known key still gets its Bulgarian label rather than the raw slug.
    func testAKnownMilestoneKeepsItsLabel() async throws {
        let d = try await decode(Self.fullAg, as: AgDashboard.self)
        let first = try XCTUnwrap(d.achievements?.milestones.first)
        XCTAssertEqual(first.key, .firstHarvest)
        XCTAssertEqual(first.label, "Първа реколта")
        XCTAssertEqual(first.id, "first-harvest")
    }

    // MARK: - Two sibling endpoints, two envelopes

    /// `/dashboard/trends` carries range metadata; `/dashboard/task-trend`
    /// answers with a bare `{trend: [...]}`. Documented rather than
    /// discovered — a client that assumed the sibling's envelope would have
    /// decoded nothing and had no idea why.
    func testTheTwoTrendEndpointsHaveDifferentEnvelopes() async throws {
        let metric = try await decode(#"""
        {"dataPoints":[],"daysRequested":90,"daysAvailable":90,
         "rangeStart":"2026-06-27","rangeEnd":"2026-09-25"}
        """#, as: TrendPayload.self)
        XCTAssertEqual(metric.daysRequested, 90)

        let tasks = try await decode(#"""
        {"trend":[{"date":"2026-09-25","created":3,"completed":1}]}
        """#, as: FarmTaskTrend.self)
        XCTAssertEqual(tasks.trend.first?.created, 3)

        // The shapes really are incompatible, which is the point of keeping
        // two types rather than one generic that hides it.
        let asMetric = try? await decode(#"""
        {"trend":[{"date":"2026-09-25","created":3,"completed":1}]}
        """#, as: TrendPayload.self)
        XCTAssertNil(asMetric)
    }

    /// A young tenant has less history than the screen asked for. The server's
    /// instruction is explicit: plot the range you were GIVEN, because padding
    /// the difference with zeroes draws a collapse that never happened.
    ///
    /// Nothing here pads — `dataPoints` is exactly what arrived — and
    /// `isPartial` exists so a view can say the range is short instead of
    /// drawing sixty-nine days of nothing followed by a farm.
    func testAShortRangeIsFlaggedAndNeverPadded() async throws {
        let young = try await decode(#"""
        {"dataPoints":[{"date":"2026-09-24","evidenceOverdue":0,"evidenceDueSoon7d":0,
                        "evidenceCurrent":2,"tasksOpen":1,"tasksOverdue":0,
                        "assetsTotal":3,"assetsActive":3,"assetsHighCriticality":0,
                        "assetsRetired":0}],
         "daysRequested":90,"daysAvailable":21,
         "rangeStart":"2026-09-04","rangeEnd":"2026-09-25"}
        """#, as: TrendPayload.self)

        XCTAssertTrue(young.isPartial)
        XCTAssertEqual(young.dataPoints.count, 1, "exactly what arrived, padded to nothing")

        let whole = try await decode(#"""
        {"dataPoints":[],"daysRequested":30,"daysAvailable":30,
         "rangeStart":"2026-08-26","rangeEnd":"2026-09-25"}
        """#, as: TrendPayload.self)
        XCTAssertFalse(whole.isPartial)
    }

    // MARK: - The briefing, and why there is none

    private func briefing(ai: Bool, configured: Bool, available: Bool,
                          body: String = "null") async throws -> FieldBriefingPayload {
        try await decode("""
        {"aiConfigured":\(ai),"satelliteConfigured":\(configured),
         "satelliteAvailable":\(available),"generatedAt":"2026-09-25T06:00:00.000Z",
         "date":"2026-09-25","fieldCount":7,"briefing":\(body)}
        """, as: FieldBriefingPayload.self)
    }

    /// `briefing: null` alone says nothing a farmer can act on. THREE flags
    /// exist so a client can name the cause, and the first two are somebody
    /// else's job while the third may fix itself — which is the difference
    /// that matters to the person holding the phone.
    func testTheThreeFlagsNameThreeDifferentAbsences() async throws {
        let noModel = try await briefing(ai: false, configured: true, available: true)
        XCTAssertEqual(noModel.absence, .noModel)

        let noCreds = try await briefing(ai: true, configured: false, available: true)
        XCTAssertEqual(noCreds.absence, .noSatelliteCredentials)

        let noImagery = try await briefing(ai: true, configured: true, available: false)
        XCTAssertEqual(noImagery.absence, .imageryUnavailable)

        // Nothing in the flags explains it. Saying so beats blaming a cause
        // that is not there.
        let odd = try await briefing(ai: true, configured: true, available: true)
        XCTAssertEqual(odd.absence, .unexplained)
    }

    /// The most broken deployment reports the cause a person can act on
    /// FIRST. Order is part of the contract this type offers, not incidental.
    func testTheAbsenceOrderPrefersTheConfigurationCauses() async throws {
        let allOff = try await briefing(ai: false, configured: false, available: false)
        XCTAssertEqual(allOff.absence, .noModel)
    }

    /// And when there IS a briefing, there is no absence to report.
    func testAPresentBriefingHasNoAbsence() async throws {
        let payload = try await briefing(
            ai: true, configured: true, available: true,
            body: #"""
            {"headline":"Сухо","summary":"Три полета под стрес.",
             "actions":[{"field":"Долен блок","action":"Провери влагата","priority":"high"},
                        {"field":null,"action":"Прегледай прогнозата","priority":"low"}]}
            """#)

        XCTAssertNil(payload.absence)
        XCTAssertEqual(payload.briefing?.headline, "Сухо")
        XCTAssertEqual(payload.briefing?.actions.count, 2)
    }

    /// `field` is null for an action that applies to the WHOLE FARM. That is a
    /// meaning, not a gap — a row must not print a placeholder, because "no
    /// field" is the scope.
    func testAnActionWithNoFieldMeansTheWholeFarm() async throws {
        let payload = try await briefing(
            ai: true, configured: true, available: true,
            body: #"""
            {"headline":"h","summary":"s",
             "actions":[{"field":null,"action":"Прегледай прогнозата","priority":"medium"},
                        {"field":"   ","action":"Втора","priority":"low"}]}
            """#)

        XCTAssertNil(payload.briefing?.actions.first?.field)
        // Blank collapses to the same meaning as null — both say "no field",
        // and only one of them is expressible in the schema.
        XCTAssertNil(payload.briefing?.actions.last?.field)
    }

    /// An unrecognised priority must not fail a briefing: an action a farmer
    /// can read without a severity beats no briefing at all. And `unknown`
    /// sorts LAST — an unrecognised value is not evidence of urgency, so it
    /// must not be allowed to shout.
    func testAnUnknownPriorityIsLenientAndDoesNotShout() async throws {
        let payload = try await briefing(
            ai: true, configured: true, available: true,
            body: #"""
            {"headline":"h","summary":"s",
             "actions":[{"field":null,"action":"Нещо ново","priority":"critical"},
                        {"field":null,"action":"Спешно","priority":"high"},
                        {"field":null,"action":"Дребно","priority":"low"}]}
            """#)

        let actions = try XCTUnwrap(payload.briefing?.actions)
        XCTAssertEqual(actions.first?.priority, .unknown)

        let ordered = actions.sorted { $0.priority.rank < $1.priority.rank }
        XCTAssertEqual(ordered.first?.priority, .high)
        XCTAssertEqual(ordered.last?.priority, .unknown)
    }

    // MARK: - Dates, which none of these routes pin

    /// Not one date field across the four routes declares a `format`, so every
    /// one is parsed rather than decoded — the same asymmetry as the parcel
    /// archive, and the same reason: one unparseable value must not fail an
    /// envelope full of things that parsed.
    func testEveryDateShapeAcrossTheseRoutesParses() async throws {
        let bareDay = try await decode(#"""
        {"dataPoints":[],"daysRequested":7,"daysAvailable":7,
         "rangeStart":"2026-09-18","rangeEnd":"2026-09-25"}
        """#, as: TrendPayload.self)
        XCTAssertNotNil(bareDay.rangeStart)

        let instant = try await decode(#"""
        {"dataPoints":[],"daysRequested":7,"daysAvailable":7,
         "rangeStart":"2026-09-18T00:00:00.000Z","rangeEnd":"2026-09-25T00:00:00Z"}
        """#, as: TrendPayload.self)
        XCTAssertNotNil(instant.rangeStart)
        XCTAssertNotNil(instant.rangeEnd)

        // Unparseable is nil rather than a throw: the counts are still good.
        let bad = try await decode(#"""
        {"dataPoints":[],"daysRequested":7,"daysAvailable":7,
         "rangeStart":"осемнадесети","rangeEnd":"2026-09-25"}
        """#, as: TrendPayload.self)
        XCTAssertNil(bad.rangeStart)
        XCTAssertEqual(bad.daysRequested, 7)
    }

    // MARK: - Paths

    /// `null` and `"   "` both mean THE WHOLE FARM, so they must not be two
    /// different rows. The id was built from the raw value, so whitespace and
    /// null produced different ids for the same meaning.
    func testTheTwoSpellingsOfWholeFarmShareOneIdentity() async throws {
        let payload = try await briefing(
            ai: true, configured: true, available: true,
            body: #"""
            {"headline":"h","summary":"s",
             "actions":[{"field":null,"action":"Едно","priority":"low"},
                        {"field":"   ","action":"Едно","priority":"low"}]}
            """#)
        let actions = try XCTUnwrap(payload.briefing?.actions)
        XCTAssertEqual(actions.first?.id, actions.last?.id,
                       "same scope, same action, same row")
    }

    /// `days` is `exclusiveMinimum: 0`, and a non-numeric value makes the
    /// server fall back to its default SILENTLY — drawing a convincing chart of
    /// the wrong period. A request this client knows to be invalid is not made.
    func testAnOutOfRangeWindowIsClampedRatherThanSent() {
        XCTAssertTrue(DashboardAPI.trendsPath(days: 0).hasSuffix("days=1"))
        XCTAssertTrue(DashboardAPI.trendsPath(days: -30).hasSuffix("days=1"))
        XCTAssertTrue(DashboardAPI.taskTrendPath(days: 0).hasSuffix("days=1"))
    }

    /// The two routes DEFAULT to different windows — 90 and 14 — so omitting
    /// the parameter on both compares a quarter against a fortnight. Named
    /// constants exist so a caller can pass one window to both deliberately.
    func testTheTwoRoutesDefaultToDifferentWindows() {
        XCTAssertEqual(DashboardAPI.DefaultWindow.metrics, 90)
        XCTAssertEqual(DashboardAPI.DefaultWindow.tasks, 14)
        XCTAssertNotEqual(DashboardAPI.DefaultWindow.metrics,
                          DashboardAPI.DefaultWindow.tasks)
    }

    func testThePathsMatchTheSpec() {
        XCTAssertTrue(DashboardAPI.agPath.hasSuffix("/dashboard/ag"))
        XCTAssertTrue(DashboardAPI.trendsPath().hasSuffix("/dashboard/trends"))
        XCTAssertTrue(DashboardAPI.taskTrendPath().hasSuffix("/dashboard/task-trend"))
        XCTAssertTrue(DashboardAPI.trendsPath(days: 30).hasSuffix("/trends?days=30"))
        // Under /reports, not /dashboard — the prefix decides which roles the
        // server's lockdown lets through, so it is not cosmetic.
        XCTAssertTrue(DashboardAPI.fieldBriefingPath.hasSuffix("/reports/field-briefing"))
    }
}
