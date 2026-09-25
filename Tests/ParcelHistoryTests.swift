import XCTest
@testable import Agrent

/// The parcel archive, tested against the shapes in the GENERATED spec.
///
/// Every JSON literal below was written from `src/generated/openapi.json` on
/// agri-saas `main` (fetched 2026-09-25) rather than from a relayed
/// description, because four contract defects this month were relayed
/// descriptions that nothing checked: an insurance `message` field that
/// never reached the server, a 409 guard the client could not trigger, a
/// crop value this repo's own fixture invented, and an idempotency list
/// wrong in both directions.
final class ParcelHistoryTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type) async throws -> T {
        try await APIClient.shared.decode(Data(json.utf8), as: type)
    }

    // MARK: - The harvest year is read, never derived

    /// THE test on this model.
    ///
    /// Wheat drilled in October 2025 is the 2026 harvest. A client that took
    /// the year from `sownAt` would file it under 2025 — and every autumn
    /// crop in Bulgaria with it, which is most of the archive. Every row
    /// would still look plausible; only the per-year totals would be wrong,
    /// which is why this needs a test rather than a look.
    func testTheHarvestYearIsTakenFromYearAndNotFromTheSowingDate() async throws {
        let season = try await decode(#"""
        {"id":"cs_1","year":2026,"cropType":"Wheat",
         "sownAt":"2025-10-14T00:00:00.000Z","harvestedAt":null,"notes":null}
        """#, as: CropSeason.self)

        XCTAssertEqual(season.year, 2026)

        // And the sowing really is in the PREVIOUS calendar year, so the
        // assertion above is not accidentally agreeing with a derivation.
        let sownYear = Calendar(identifier: .gregorian)
            .component(.year, from: try XCTUnwrap(season.sownAt))
        XCTAssertEqual(sownYear, 2025)
        XCTAssertNotEqual(sownYear, season.year)
    }

    /// A back-filled season is often remembered without the drilling date —
    /// the server's own reason for making it optional. A form that required
    /// it would make the oldest half of an archive unwritable.
    func testASeasonWithNoDatesDecodes() async throws {
        let season = try await decode(#"""
        {"id":"cs_2","year":1998,"cropType":"Слънчоглед",
         "sownAt":null,"harvestedAt":null,"notes":null}
        """#, as: CropSeason.self)

        XCTAssertNil(season.sownAt)
        XCTAssertNil(season.harvestedAt)
        XCTAssertNil(season.notes)
        XCTAssertEqual(season.year, 1998)
    }

    // MARK: - The dates the response schema does not pin

    /// The reads declare `type: string` with NO format while the writes
    /// declare `date-time`, so a date-only value is something the published
    /// contract still permits. Declared as `Date` properties these would
    /// decode through `APIClient`'s strategy, which throws on anything that
    /// is not an instant — and a throw on one season's `sownAt` fails the
    /// WHOLE archive payload.
    ///
    /// So the parse is lenient and this proves all three shapes arrive.
    func testAllThreeDateShapesParse() {
        XCTAssertNotNil(BgDate.parseInstantOrDay("2026-09-19T08:30:00.000Z"))
        XCTAssertNotNil(BgDate.parseInstantOrDay("2026-09-19T08:30:00Z"))
        XCTAssertNotNil(BgDate.parseInstantOrDay("2026-09-19"))
        XCTAssertNil(BgDate.parseInstantOrDay(nil))
        XCTAssertNil(BgDate.parseInstantOrDay(""))
        XCTAssertNil(BgDate.parseInstantOrDay("осемнадесети"))
    }

    /// The instant and the day must agree on the CALENDAR DAY, or the same
    /// archive shows one season on the 19th and the next on the 18th
    /// depending on which shape the server happened to send. `parseISODay`
    /// already uses `.current` for exactly this reason, so the comparison is
    /// in the device's zone too.
    ///
    /// ELEVEN HUNDRED UTC, not 08:30. The instant has to be far enough from
    /// both midnights that this holds in the CI runner's zone as well as this
    /// phone's — `Num.text` failed on CI only, last week, because a test
    /// pinned something the machine owned rather than the code. 11:00Z is the
    /// same calendar day from UTC-11 through UTC+12.
    func testAnInstantAndABareDayLandOnTheSameDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let instant = try XCTUnwrap(BgDate.parseInstantOrDay("2026-09-19T11:00:00.000Z"))
        let day = try XCTUnwrap(BgDate.parseInstantOrDay("2026-09-19"))
        XCTAssertTrue(calendar.isDate(instant, inSameDayAs: day))
    }

    /// One loose date must not cost the archive. A mixed array — instant,
    /// bare day, null — decodes whole.
    func testAMixedArrayOfDateShapesDecodesWhole() async throws {
        let seasons = try await decode(#"""
        [{"id":"a","year":2026,"cropType":"Wheat","sownAt":"2025-10-14T00:00:00.000Z",
          "harvestedAt":null,"notes":null},
         {"id":"b","year":2025,"cropType":"Maize","sownAt":"2025-04-02",
          "harvestedAt":"2025-09-30","notes":"късна"},
         {"id":"c","year":2024,"cropType":"Grass","sownAt":null,
          "harvestedAt":null,"notes":null}]
        """#, as: [CropSeason].self)

        XCTAssertEqual(seasons.count, 3)
        XCTAssertNotNil(seasons[1].sownAt)
        XCTAssertNotNil(seasons[1].harvestedAt)
    }

    // MARK: - Grouping

    /// A catch crop after an early harvest is ordinary practice and the
    /// server does not refuse it as a duplicate, so a year holds more than
    /// one season and anything keyed on year alone loses one of them.
    func testTwoSeasonsInOneYearBothSurviveGrouping() async throws {
        let seasons = try await decode(#"""
        [{"id":"a","year":2026,"cropType":"Wheat","sownAt":null,"harvestedAt":null,"notes":null},
         {"id":"b","year":2026,"cropType":"Sunflower","sownAt":null,"harvestedAt":null,"notes":null},
         {"id":"c","year":2024,"cropType":"Maize","sownAt":null,"harvestedAt":null,"notes":null}]
        """#, as: [CropSeason].self)

        let grouped = seasons.groupedByYear()
        XCTAssertEqual(grouped.map(\.year), [2026, 2024])
        XCTAssertEqual(grouped.first?.seasons.count, 2)
        XCTAssertEqual(grouped.last?.seasons.count, 1)
    }

    /// Free text, open set. The server does not validate `cropType` against
    /// the catalogue and says why: live data already holds values outside
    /// it. So an unmapped crop shows what the farm typed rather than nothing.
    func testAnUnmappedCropShowsWhatTheFarmTyped() async throws {
        let season = try await decode(#"""
        {"id":"x","year":2026,"cropType":"Фий","sownAt":null,"harvestedAt":null,"notes":null}
        """#, as: CropSeason.self)
        XCTAssertEqual(season.cropLabel, "Фий")
    }

    func testAKnownCropIsShownInBulgarian() async throws {
        let season = try await decode(#"""
        {"id":"x","year":2026,"cropType":"Wheat","sownAt":null,"harvestedAt":null,"notes":null}
        """#, as: CropSeason.self)
        XCTAssertEqual(season.cropLabel, "Пшеница")
        XCTAssertFalse(season.cropLabel.contains("Wheat"))
    }

    // MARK: - The completed operation, and its dose

    private static let sprayLine = #"""
    {"id":"line_1","taskId":"task_9","operationType":"SPRAY","title":"Хербицид",
     "completedAt":"2026-05-03T06:12:00.000Z","productName":"Раундъп",
     "doseValue":"2.5","doseUnit":"л/дка","targetNote":"балур на петна"}
    """#

    func testACompletedLineDecodes() async throws {
        let line = try await decode(Self.sprayLine, as: ParcelHistoryOperation.self)
        XCTAssertEqual(line.id, "line_1")
        XCTAssertEqual(line.taskId, "task_9")
        XCTAssertEqual(line.operationType, .spray)
        XCTAssertEqual(line.productName, "Раундъп")
        XCTAssertNotNil(line.completedAt)
    }

    /// `doseValue` is a decimal STRING and the server's warning is explicit:
    /// parsing it as a float rounds the dose. This is the number an operator
    /// sets a boom to.
    func testTheDoseKeepsItsDigitsExactly() async throws {
        let line = try await decode(Self.sprayLine, as: ParcelHistoryOperation.self)
        XCTAssertEqual(line.doseValue.value, Decimal(string: "2.5"))
        XCTAssertEqual(line.doseValue.raw, "2.5")
    }

    /// A dose with more decimals than any money column would carry must not
    /// be rounded to two on the way to a screen.
    func testAFinerDoseIsNotRoundedForDisplay() async throws {
        let json = Self.sprayLine.replacingOccurrences(of: #""2.5""#, with: #""0.125""#)
        let line = try await decode(json, as: ParcelHistoryOperation.self)
        XCTAssertEqual(line.doseValue.value, Decimal(string: "0.125"))
        XCTAssertTrue(line.doseText.hasPrefix("0,125"), line.doseText)
    }

    /// The server's own digits, localised — NOT padded to a scale nobody
    /// published. `2.5` shows as `2,5`, not as `2,50`: padding is only
    /// honest when the column's scale is known, and the parcel-history spec
    /// does not state one.
    func testTheDoseIsShownWithTheDigitsTheServerSentAndABulgarianComma() async throws {
        let line = try await decode(Self.sprayLine, as: ParcelHistoryOperation.self)
        XCTAssertEqual(line.doseText, "2,5 л/дка")

        let whole = Self.sprayLine.replacingOccurrences(of: #""2.5""#, with: #""3""#)
        let rounded = try await decode(whole, as: ParcelHistoryOperation.self)
        XCTAssertEqual(rounded.doseText, "3 л/дка")
    }

    /// `operationType` is nullable, and an unrecognised value must not fail
    /// the payload — `FieldOperationType` is `LenientDecodable` for exactly
    /// that, and reusing it here is what keeps this projection from growing
    /// a second vocabulary.
    func testTheOperationTypeIsNullableAndLenient() async throws {
        let none = Self.sprayLine.replacingOccurrences(of: #""SPRAY""#, with: "null")
        let untyped = try await decode(none, as: ParcelHistoryOperation.self)
        XCTAssertNil(untyped.operationType)

        let future = Self.sprayLine.replacingOccurrences(of: #""SPRAY""#, with: #""DESICCATE""#)
        let unrecognised = try await decode(future, as: ParcelHistoryOperation.self)
        XCTAssertEqual(unrecognised.operationType, .unknown)
    }

    // MARK: - Weeds: the server's split, kept

    private static let observation = #"""
    {"id":"wo_1","observedAt":"2026-06-11T05:40:00.000Z",
     "weedKeys":["Sorghum halepense","Galium aparine"],
     "otherWeeds":["някакъв друг плевел"],"notes":null}
    """#

    func testTheTwoHalvesStayApartInStorage() async throws {
        let seen = try await decode(Self.observation, as: WeedObservation.self)
        XCTAssertEqual(seen.weedKeys, ["Sorghum halepense", "Galium aparine"])
        XCTAssertEqual(seen.otherWeeds, ["някакъв друг плевел"])
    }

    /// Rendered together, catalogue first — and the free text is not
    /// translated, because it is whatever somebody typed.
    func testBothHalvesRenderTogetherWithTheCatalogueFirst() async throws {
        let seen = try await decode(Self.observation, as: WeedObservation.self)
        XCTAssertEqual(seen.displayNames.count, 3)
        XCTAssertTrue(seen.displayNames[0].hasPrefix("балур"), seen.displayNames[0])
        XCTAssertEqual(seen.displayNames.last, "някакъв друг плевел")
    }

    /// The catalogue is NOT in the generated spec — `Sorghum halepense`
    /// appears there once, as an example — so this table is a relayed list
    /// the client cannot verify. A fourteenth weed added server-side must
    /// therefore render as its binomial rather than as a blank or a wrong
    /// name, which is the only safe direction for an unverifiable list.
    func testAWeedThisBuildDoesNotKnowRendersAsItsBinomial() {
        XCTAssertEqual(WeedCatalogue.name(for: "Lolium perenne"), "Lolium perenne")
    }

    /// The Latin stays beside the Bulgarian: it is what the server stores,
    /// what a spray label says, and the half of the pair this client did not
    /// write itself.
    func testAKnownWeedCarriesBothNames() {
        let name = WeedCatalogue.name(for: "Cirsium arvense")
        XCTAssertTrue(name.contains("паламида"), name)
        XCTAssertTrue(name.contains("Cirsium arvense"), name)
    }

    func testTheCatalogueHasNoDuplicateKeysOrNames() {
        let keys = WeedCatalogue.entries.map(\.key)
        let names = WeedCatalogue.entries.map(\.value)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(keys, WeedCatalogue.binomials)
    }

    // MARK: - The writes

    /// `weeds` must be non-empty or the server refuses the observation, so
    /// the cleaning that makes `isEmpty` an honest submit guard happens
    /// before the request rather than after the 400.
    func testCleaningMakesAnEmptySubmitDetectableBeforeSending() {
        XCTAssertEqual(NewWeedObservation.cleaned(["  ", "", "\n"]), [])
        XCTAssertEqual(NewWeedObservation.cleaned([" балур ", "балур", "БАЛУР"]), ["балур"])
        XCTAssertEqual(
            NewWeedObservation.cleaned(["Sorghum halepense", "лепка"]),
            ["Sorghum halepense", "лепка"]
        )
    }

    /// Encoded through THIS client's encoder, not a fresh one — the date
    /// strategy is the client's and a local `JSONEncoder` would be testing a
    /// different payload from the one that gets sent.
    private func encoded<B: Encodable>(_ body: B) async throws -> String {
        String(decoding: try await APIClient.shared.encodeBody(body), as: UTF8.self)
    }

    /// The writes DO declare `date-time`, so a sowing date goes out as an
    /// instant even though the read of it is unpinned.
    func testASowingDateIsSentAsAnInstant() async throws {
        let season = NewCropSeason(
            year: 2026, cropType: "Wheat",
            sownAt: Date(timeIntervalSince1970: 1_760_400_000),
            harvestedAt: nil, notes: nil
        )
        let json = try await encoded(season)
        XCTAssertTrue(json.contains("\"year\":2026"), json)
        XCTAssertTrue(json.contains("\"sownAt\":\"2025-10-"), json)
        XCTAssertTrue(json.contains("T"), json)
    }

    /// An omitted optional is absent rather than null. Both are accepted —
    /// `year` and `cropType` are the only required fields — and absence is
    /// the shape a synthesised encoder produces, so this pins it rather than
    /// leaving the next reader to guess.
    func testUnsetOptionalsAreOmittedRatherThanSentAsNull() async throws {
        let json = try await encoded(NewCropSeason(
            year: 1998, cropType: "Слънчоглед",
            sownAt: nil, harvestedAt: nil, notes: nil
        ))
        XCTAssertFalse(json.contains("sownAt"), json)
        XCTAssertFalse(json.contains("null"), json)
        XCTAssertTrue(json.contains("\"cropType\":\"Слънчоглед\""), json)
    }

    // MARK: - Delete

    /// A 404 on a delete is the outcome the caller wanted: the id came out
    /// of the archive this client just read, so its absence means another
    /// device removed it or this device's own retry already did.
    ///
    /// Asserted against the error the client ACTUALLY throws. The 409 guard
    /// in `FarmRiskModels` matched a case the client never threw, so it was
    /// unreachable and the feature never worked — a test at this level is
    /// what that cost.
    func testA404OnDeleteIsTreatedAsAlreadyDeleted() {
        XCTAssertTrue(ParcelHistoryAPI.isAlreadyDeleted(
            APIClient.APIError.http(status: 404, code: "NOT_FOUND", message: "нема")
        ))
    }

    /// Everything else is a real failure. A 403 in particular must NOT read
    /// as success — a delete refused for permissions leaves the row in
    /// place, and reporting it as done would show an archive the server does
    /// not have.
    func testEveryOtherRefusalStaysAFailure() {
        let others: [Error] = [
            APIClient.APIError.http(status: 403, code: "FORBIDDEN", message: nil),
            APIClient.APIError.http(status: 500, code: nil, message: nil),
            APIClient.APIError.clientTooOld,
            APIClient.APIError.notSignedIn,
            APIClient.APIError.conflict(currentVersion: 2, expectedVersion: 1),
            URLError(.timedOut),
        ]
        for error in others {
            XCTAssertFalse(ParcelHistoryAPI.isAlreadyDeleted(error), "\(error)")
        }
    }

    // MARK: - Paths

    func testThePathsMatchTheSpec() {
        XCTAssertTrue(
            ParcelHistoryAPI.cropSeasonsPath("p1")
                .hasSuffix("/agro/parcels/p1/crop-seasons"),
            ParcelHistoryAPI.cropSeasonsPath("p1")
        )
        XCTAssertTrue(
            ParcelHistoryAPI.weedObservationsPath("p1")
                .hasSuffix("/agro/parcels/p1/weed-observations"),
            ParcelHistoryAPI.weedObservationsPath("p1")
        )
    }
}
