import XCTest
@testable import Agrent

/// The risk readings, against the server's real `ParcelRiskResult` shape.
@MainActor
final class FarmRiskDecodeTests: XCTestCase {

    /// Captured from the contract: flat, every key present, absence as
    /// `null` rather than a missing key.
    private let reading = """
    {"parcelId":"cmr3vn01","name":"15655-19","areaHa":12.4,"cropType":"wheat",
     "configured":true,"ndvi":0.612,"ndmi":0.184,
     "vegetation":"good","moisture":"watch","overall":"watch",
     "acquiredDate":"2026-09-14","generatedAt":"2026-09-23T13:41:07.221Z"}
    """

    private func decode(_ json: String) async throws -> ParcelRisk {
        try await FarmRiskAPI.decodeAnalysis(from: Data(json.utf8))
    }

    func testTheRealShapeDecodes() async throws {
        let risk = try await decode(reading)
        XCTAssertEqual(risk.name, "15655-19")
        XCTAssertEqual(risk.ndvi, 0.612)
        XCTAssertEqual(risk.ndmi, 0.184)
        XCTAssertEqual(risk.vegetation, .good)
        XCTAssertEqual(risk.moisture, .watch)
        XCTAssertEqual(risk.overall, .watch)
    }

    /// `acquiredDate` is a DAY and `generatedAt` is an INSTANT — one object
    /// carrying both shapes, needing different parsers. Parsing the day as
    /// an instant shifts it a timezone.
    func testTheTwoDateShapesAreParsedDifferently() async throws {
        let risk = try await decode(reading)
        let day = try XCTUnwrap(risk.acquired)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 14)
        XCTAssertGreaterThan(risk.generatedAt, day, "generatedAt is the later instant")
    }

    /// Nine days, from two SERVER timestamps. A rural device clock must not
    /// be able to relabel a stale pass as current.
    func testStalenessComesFromTheServerNotTheDevice() async throws {
        let risk = try await decode(reading)
        XCTAssertEqual(risk.staleDays, 9)
    }

    // MARK: - The two absences

    /// `configured: false` returns the FULL object with nulls, not a
    /// partial one. The parcel's own facts stay real — they come from the
    /// database, not from Earth Engine.
    func testUnconfiguredKeepsTheParcelsOwnFacts() async throws {
        let risk = try await decode("""
        {"parcelId":"p","name":"15655-19","areaHa":12.4,"cropType":"wheat",
         "configured":false,"ndvi":null,"ndmi":null,
         "vegetation":"unknown","moisture":"unknown","overall":"unknown",
         "acquiredDate":null,"generatedAt":"2026-09-23T13:41:07.221Z"}
        """)
        XCTAssertEqual(risk.name, "15655-19")
        XCTAssertEqual(risk.areaHa, 12.4)
        XCTAssertNil(risk.ndvi)
        XCTAssertNil(risk.staleDays)
    }

    /// THE FIELD THAT SEPARATES THEM. A parcel with no geometry and a
    /// deployment with no Earth Engine are IDENTICAL in every field except
    /// `configured` — same nulls, same `unknown` levels. They need
    /// different sentences because they need different actions.
    func testTheTwoAbsencesAreDistinguished() async throws {
        let noEngine = try await decode("""
        {"parcelId":"p","name":"A","areaHa":null,"cropType":null,"configured":false,
         "ndvi":null,"ndmi":null,"vegetation":"unknown","moisture":"unknown",
         "overall":"unknown","acquiredDate":null,"generatedAt":"2026-09-23T13:41:07.221Z"}
        """)
        let noGeometry = try await decode("""
        {"parcelId":"p","name":"A","areaHa":null,"cropType":null,"configured":true,
         "ndvi":null,"ndmi":null,"vegetation":"unknown","moisture":"unknown",
         "overall":"unknown","acquiredDate":null,"generatedAt":"2026-09-23T13:41:07.221Z"}
        """)
        XCTAssertNotNil(noEngine.absenceReason)
        XCTAssertNotNil(noGeometry.absenceReason)
        XCTAssertNotEqual(noEngine.absenceReason, noGeometry.absenceReason,
                          "the two absences must not read the same")
        XCTAssertTrue(noEngine.absenceReason!.contains("стопанство"))
        XCTAssertTrue(noGeometry.absenceReason!.contains("парцел"))
    }

    /// A reading present means no absence sentence at all.
    func testAReadingHasNoAbsenceSentence() async throws {
        let risk = try await decode(reading)
        XCTAssertNil(risk.absenceReason)
    }

    /// `overall` is the server's, not recomputed. Two implementations of
    /// one rule is how they drift — asserted by feeding it an `overall`
    /// that disagrees with a naive local max and checking it survives.
    func testOverallIsTakenFromTheServer() async throws {
        let risk = try await decode("""
        {"parcelId":"p","name":"A","areaHa":null,"cropType":null,"configured":true,
         "ndvi":0.9,"ndmi":0.9,"vegetation":"good","moisture":"good",
         "overall":"stress","acquiredDate":"2026-09-14",
         "generatedAt":"2026-09-23T13:41:07.221Z"}
        """)
        XCTAssertEqual(risk.overall, .stress, "overall was recomputed locally")
    }
}

final class RiskLevelTests: XCTestCase {

    private let serverValues = ["good", "watch", "stress", "unknown"]

    func testTheFourValuesMatchTheServer() {
        XCTAssertEqual(Set(RiskLevel.allCases.map(\.rawValue)), Set(serverValues))
    }

    /// A fifth value must not fail the decode of a parcel — the
    /// `LogEntryType` lesson, where strict decoding would have blanked a
    /// whole list on one unrecognised string.
    func testAnUnknownValueDegrades() throws {
        let decoded = try JSONDecoder().decode(RiskLevel.self, from: Data("\"severe\"".utf8))
        XCTAssertEqual(decoded, .unknown)
    }

    /// `unknown` is an ABSENT READING, not a fourth severity. Colouring it
    /// on the scale would assert a measurement nobody took.
    func testUnknownIsNeutralNotASeverity() {
        let severities = [RiskLevel.good, .watch, .stress].map(\.colors.background)
        XCTAssertFalse(severities.contains(RiskLevel.unknown.colors.background),
                       "unknown borrowed a severity colour")
        XCTAssertFalse(RiskLevel.unknown.isReading)
        XCTAssertTrue(RiskLevel.good.isReading)
    }

    /// Worst first — but a GAP sorts last, not first. Putting unread
    /// parcels above stressed ones buries the field that needs spraying
    /// under the fields a cloud happened to cover.
    func testWorstFirstAndGapsLast() {
        let sorted = RiskLevel.allCases.sorted { $0.severityOrder < $1.severityOrder }
        XCTAssertEqual(sorted, [.stress, .watch, .good, .unknown])
    }

    func testEveryLevelHasADistinctBulgarianLabel() {
        let labels = RiskLevel.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        for level in RiskLevel.allCases {
            XCTAssertNotEqual(level.label, level.rawValue)
            XCTAssertTrue(level.label.unicodeScalars.contains {
                $0.properties.isAlphabetic && $0.value > 0x400
            }, level.label)
        }
    }

    /// The parcel id is a PATH SEGMENT, not a query parameter — Apple's
    /// CFNetwork writes full URLs to the device log unsuppressably, so an
    /// id in a query string is an id in the log.
    func testTheParcelIdIsNotInAQueryString() {
        let path = FarmRiskAPI.analysisPath("cmr3vn01")
        XCTAssertTrue(path.hasSuffix("/agro/parcels/cmr3vn01/analysis"), path)
        XCTAssertFalse(path.contains("?"))
    }
}

/// The insurance ask, which cannot be taken back.
///
/// A 15-minute undo was specified and then dropped by the owner. That
/// makes the confirmation dialog the ONLY protection a farmer has, and
/// makes every decision below load-bearing rather than merely tidy.
@MainActor
final class InsuranceAskTests: XCTestCase {

    /// 409 means "already asked", not "failed". Treating it as an error
    /// tells a farmer their ask did not go through when it went through
    /// the first time — and invites the retry that produces the same 409
    /// forever.
    func testAlreadyAskedIsRecognised() {
        XCTAssertTrue(FarmRiskAPI.isAlreadyAsked(
            APIClient.APIError.http(status: 409, code: nil, message: nil)))
    }

    /// Everything else is a real failure. A 403 in particular must NOT be
    /// read as success — that is an operator being refused, and recording
    /// it as asked would show them a parcel as spent when nothing happened.
    func testOtherStatusesAreNotSuccess() {
        for status in [400, 401, 403, 404, 422, 500, 503] {
            XCTAssertFalse(FarmRiskAPI.isAlreadyAsked(
                APIClient.APIError.http(status: status, code: nil, message: nil)),
                "a \(status) was treated as already-asked")
        }
        XCTAssertFalse(FarmRiskAPI.isAlreadyAsked(URLError(.notConnectedToInternet)))
    }

    func testTheLeadsShapeDecodes() async throws {
        let leads = try await FarmRiskAPI.decodeLeads(
            from: Data(#"{"parcelIds":["a","b"]}"#.utf8))
        XCTAssertEqual(Set(leads.parcelIds), ["a", "b"])
    }

    func testTheCreatePayloadCarriesTheParcel() throws {
        let data = try JSONEncoder().encode(CreateLead(parcelId: "cmr3vn01"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["parcelId"] as? String, "cmr3vn01")
        XCTAssertEqual(json.keys.count, 1, "the create sends exactly one field")
    }

    /// The source-level guarantees. These are the ones that protect a
    /// farmer from an irreversible write, and none of them has a runtime
    /// seam worth hosting a view for.
    private var viewSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent(
            "Agrent/FarmRisk/FarmRiskView.swift"), encoding: .utf8)) ?? ""
    }

    private var storeSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent(
            "Agrent/FarmRisk/FarmRiskStore.swift"), encoding: .utf8)) ?? ""
    }

    func testTheSourcesAreRead() {
        XCTAssertTrue(viewSource.contains("struct FarmRiskView"), "positive control")
        XCTAssertTrue(storeSource.contains("final class FarmRiskStore"), "positive control")
    }

    /// The dialog NAMES the parcel. "Are you sure?" over an unnamed action
    /// is a speed bump, not a confirmation — and with no undo, picking the
    /// wrong field is unrecoverable.
    func testTheConfirmationNamesTheParcel() {
        XCTAssertTrue(viewSource.contains("confirming?.parcel.name"),
                      "the dialog title does not name the parcel")
        XCTAssertTrue(viewSource.contains("row.parcel.name"),
                      "the dialog body does not name the parcel")
    }

    /// It says the ask cannot be withdrawn. After this there is nowhere
    /// left to say it.
    func testTheConfirmationSaysItCannotBeTakenBack() {
        XCTAssertTrue(viewSource.contains("не може да бъде оттеглено"),
                      "the dialog does not state that the ask is irreversible")
        XCTAssertTrue(viewSource.contains("само веднъж"),
                      "the dialog does not state one ask per parcel")
    }

    /// NEVER retried automatically. A lost response on a bad connection
    /// must not turn one deliberate tap into something the farmer did not
    /// choose.
    func testTheAskIsNeverRetriedAutomatically() {
        XCTAssertFalse(storeSource.contains("PendingOperations"),
                       "the insurance ask can reach the offline outbox")
        XCTAssertFalse(storeSource.contains("isWorthRetrying"),
                       "the insurance ask is being classified for retry")
    }

    /// A failed leads READ must not clear the set — that would re-enable a
    /// button whose write the server then refuses.
    func testAFailedLeadsReadDoesNotClearWhatIsKnown() {
        XCTAssertFalse(storeSource.contains("askedParcelIDs = []"),
                       "a failure path empties the asked set")
    }
}
