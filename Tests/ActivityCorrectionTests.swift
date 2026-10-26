import XCTest
@testable import Agrent

/// «Коригирай» on pruning, cultivation or a harvest (#439; agri-saas #2375):
/// the day and a harvest's total, on the activities' own route.
@MainActor
final class ActivityCorrectionTests: XCTestCase {

    private func entry(kind: String?, mayCorrect: Bool? = true) -> LogEntry {
        LogEntry(id: "e", type: .activity, status: .done, title: "Резитба", occurredAt: nil,
                 treatment: JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 2, kind: kind,
                                             mayDelete: true, mayCorrect: mayCorrect))
    }

    private let writer = CurrentUser(id: "u", name: nil, email: nil, role: nil,
                                     permissions: CurrentUser.Permissions(canWrite: true, canAdmin: false))
    private let reader = CurrentUser(id: "r", name: nil, email: nil, role: nil,
                                     permissions: CurrentUser.Permissions(canWrite: false, canAdmin: false))

    private func definition(kind: String = "HARVEST", harvestKg: Decimal? = 4200) -> ActivityDefinition {
        ActivityDefinition(treatmentGroupId: "tg_1", version: 3, kind: kind, occurredOn: "2026-09-08",
                           harvestKg: harvestKg, lines: [])
    }

    private func json(_ body: ActivityCorrection.Body) throws -> NSDictionary {
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func day(_ iso: String) throws -> Date { try XCTUnwrap(BgDate.parseISODay(iso)) }

    // MARK: - Who is offered it

    /// The three kinds the route corrects, on the row's own flag; and only
    /// one of the two routes for any kind, as each refuses the other's.
    func testOtherWorkIsOfferedItsOwnCorrection() {
        for kind in ["PRUNE", "CULTIVATE", "HARVEST"] {
            XCTAssertTrue(ActivityCorrection.offered(entry(kind: kind), to: writer), kind)
            XCTAssertTrue(ActivityCorrection.offered(entry(kind: kind, mayCorrect: nil), to: writer), kind)
            XCTAssertFalse(ActivityCorrection.offered(entry(kind: kind, mayCorrect: false), to: writer), kind)
            XCTAssertFalse(ActivityCorrection.offered(entry(kind: kind), to: reader), kind)
            XCTAssertFalse(TreatmentCorrection.offered(entry(kind: kind), to: writer), kind)
        }
        for kind in ["SPRAY", "FERTILIZE", "SEED", nil] {
            XCTAssertFalse(ActivityCorrection.offered(entry(kind: kind), to: writer), kind ?? "nil")
            XCTAssertTrue(TreatmentCorrection.offered(entry(kind: kind), to: writer), kind ?? "nil")
        }
        // A kind this build doesn't know goes to neither route.
        XCTAssertFalse(ActivityCorrection.offered(entry(kind: "SOMETHING_NEW"), to: writer))
        XCTAssertFalse(TreatmentCorrection.offered(entry(kind: "SOMETHING_NEW"), to: writer))
    }

    func testThePathsAreTheActivitiesOwn() {
        XCTAssertTrue(ActivityCorrectionAPI.definitionPath("tg 1").hasSuffix("/journal/activities/tg%201/definition"),
                      ActivityCorrectionAPI.definitionPath("tg 1"))
        XCTAssertTrue(ActivityCorrectionAPI.correctionsPath("tg 1").hasSuffix("/journal/activities/tg%201/corrections"),
                      ActivityCorrectionAPI.correctionsPath("tg 1"))
    }

    // MARK: - The definition

    func testTheDefinitionReadsAsTheSpecGivesIt() async throws {
        let read = try await APIClient.shared.decode(Data(#"""
            {"treatmentGroupId":"tg_1","version":0,"kind":"PRUNE","occurredOn":null,"harvestKg":null,
             "parcelCount":1,"lines":[{"parcelId":"p1","parcelName":null,"locationId":null,"treatedAreaHa":null}]}
            """#.utf8), as: ActivityDefinition.self)
        XCTAssertEqual(read.activity, .prune)
        XCTAssertNil(read.occurredOn)
        XCTAssertNil(read.harvestKg)
        XCTAssertEqual(read.lines.map(\.parcelId), ["p1"])

        let harvest = try await APIClient.shared.decode(Data(#"""
            {"treatmentGroupId":"tg_2","version":4,"kind":"HARVEST","occurredOn":"2026-09-08","harvestKg":4200.5,
             "parcelCount":0,"lines":[]}
            """#.utf8), as: ActivityDefinition.self)
        XCTAssertEqual(harvest.harvestKg, Decimal(string: "4200.5"))
        XCTAssertEqual(harvest.version, 4)
    }

    // MARK: - The form

    func testNothingChangedIsSaid() {
        let draft = ActivityCorrection.Draft(definition())
        XCTAssertEqual(draft.problems(), [.nothingChanged])
        XCTAssertEqual(draft.harvestText, "4200")
    }

    /// Only what changed goes out: an omitted field is left as it is.
    func testOnlyTheChangedFieldsGoOut() throws {
        var draft = ActivityCorrection.Draft(definition())
        draft.date = try day("2026-09-07")
        XCTAssertEqual(draft.problems(), [])
        XCTAssertEqual(try json(draft.body), ["occurredOn": "2026-09-07"])

        draft = ActivityCorrection.Draft(definition())
        draft.harvestText = "4 300,5"
        XCTAssertEqual(try json(draft.body), ["harvestKg": 4300.5])

        draft.date = try day("2026-09-07")
        XCTAssertEqual(try json(draft.body), ["occurredOn": "2026-09-07", "harvestKg": 4300.5])
    }

    /// A recorded total may be corrected, never emptied; one never recorded
    /// may stay so.
    func testAHarvestTotalIsCorrectedNotCleared() {
        var draft = ActivityCorrection.Draft(definition())
        draft.harvestText = ""
        XCTAssertEqual(draft.problems().first, .harvestMissing)
        XCTAssertEqual(draft.problems().first?.text, "Въведете прибраното количество в килограми.")
        for bad in ["0", "-5", "много"] {
            draft.harvestText = bad
            XCTAssertEqual(draft.problems().first, .harvestNotPositive, bad)
        }

        let never = ActivityCorrection.Draft(definition(harvestKg: nil))
        XCTAssertEqual(never.harvestText, "")
        XCTAssertEqual(never.problems(), [.nothingChanged])
    }

    /// Pruning has no total: whatever the field holds is not asked or sent.
    func testOtherWorkSendsNoTotal() throws {
        var draft = ActivityCorrection.Draft(definition(kind: "PRUNE", harvestKg: nil))
        XCTAssertFalse(draft.isHarvest)
        draft.harvestText = "12"
        XCTAssertEqual(draft.problems(), [.nothingChanged])
        draft.date = try day("2026-09-01")
        XCTAssertEqual(try json(draft.body), ["occurredOn": "2026-09-01"])
    }

    func testAFutureDayIsRefused() throws {
        var draft = ActivityCorrection.Draft(definition())
        draft.date = try day("2026-09-10")
        XCTAssertEqual(draft.problems(now: try day("2026-09-09")).first, .futureDate)
    }

    /// «Проверка» reads each change back in the treatment's own words.
    func testTheChangesAreReadBack() throws {
        var draft = ActivityCorrection.Draft(definition())
        draft.date = try day("2026-09-07")
        draft.harvestText = "4300"
        XCTAssertEqual(draft.changes.map(\.label), ["Дата", "Прибрано"])
        XCTAssertEqual(draft.changes[0].before, BgDate.full(try day("2026-09-08")))
        XCTAssertEqual(draft.changes[0].after, BgDate.full(try day("2026-09-07")))
        XCTAssertEqual(draft.changes[1].before, TreatmentCheckView.kgText(4200))
        XCTAssertEqual(draft.changes[1].after, TreatmentCheckView.kgText(4300))
    }

    // MARK: - The parcels (agri-saas #2386, #447)

    private func setDraft() -> ActivityCorrection.Draft {
        ActivityCorrection.Draft(ActivityDefinition(
            treatmentGroupId: "tg_1", version: 3, kind: "PRUNE", occurredOn: "2026-09-08", harvestKg: nil,
            lines: [.init(parcelId: "p1", parcelName: "Парцел 1", locationId: "b1", treatedAreaHa: 2.2345),
                    .init(parcelId: "p2", parcelName: "Парцел 2", locationId: "b1", treatedAreaHa: nil)]))
    }

    /// A block's parcels as `/locations/{id}/parcels` lists them.
    private func block(_ id: String, _ parcels: [(String, String, Double?)]) throws -> TreatmentBlocks.Block {
        let rows = parcels.map { #"{"id":"\#($0.0)","name":"\#($0.1)","areaHa":\#($0.2.map { "\($0)" } ?? "null")}"# }
        let decoded = try JSONDecoder().decode([Parcel].self, from: Data("[\(rows.joined(separator: ","))]".utf8))
        return TreatmentBlocks.Block(id: id, name: "Блок \(id)", parcels: decoded)
    }

    private func offered() throws -> ActivityCorrection.Draft {
        var form = setDraft()
        form.offer([try block("b1", [("p1", "Парцел 1", 3), ("p2", "Парцел 2", 1.2), ("p3", "Парцел 3", 0.8)]),
                    try block("b9", [("p9", "Парцел 9", 4)])])
        return form
    }

    /// Any block may be offered, unlike a treatment's: a block the activity
    /// never covered lists its parcels unticked (owner, 2026-10-26).
    func testAnyBlocksParcelsAreOfferedUnticked() throws {
        XCTAssertEqual(setDraft().blockIDs, ["b1"])
        let form = try offered()
        XCTAssertEqual(form.parcels.map(\.id), ["p1", "p2", "p3", "p9"])
        XCTAssertEqual(form.parcels.last?.blockID, "b9")
        XCTAssertEqual(form.chosen, ["p1", "p2"])
        XCTAssertEqual(form.changed, [], "offering changes nothing")
        XCTAssertEqual(form.problems(), [.nothingChanged])
    }

    /// The whole set goes out, and an untouched parcel keeps its STORED area
    /// to the digit: the server compares exactly, and the field shows decares
    /// rounded. A whole parcel goes as its own exact area (owner, #435).
    func testTheWholeSetGoesOutWithUntouchedAreasAsStored() throws {
        var form = try offered()
        form.chosen.insert("p9")
        XCTAssertEqual(form.changed, [.parcels])
        XCTAssertEqual(try json(form.body), [
            "parcelIds": ["p1", "p2", "p9"],
            "parcels": [["parcelId": "p1", "treatedAreaHa": 2.2345], ["parcelId": "p2", "treatedAreaHa": 1.2],
                        ["parcelId": "p9", "treatedAreaHa": 4]],
        ])
        XCTAssertEqual(form.changes.map(\.label), ["Добавен парцел"])
        XCTAssertEqual(form.changes.first?.after, "Парцел 9 — \(Area(hectares: 4).text)")
    }

    func testADroppedParcelIsReadBack() throws {
        var form = try offered()
        form.chosen.remove("p2")
        XCTAssertEqual(try json(form.body), [
            "parcelIds": ["p1"], "parcels": [["parcelId": "p1", "treatedAreaHa": 2.2345]],
        ])
        XCTAssertEqual(form.changes.map(\.label), ["Премахнат парцел"])
        XCTAssertEqual(form.changes.first?.before, "Парцел 2")
    }

    /// A mistyped area on a parcel that stays is correctable; emptying it is
    /// the whole parcel, sent as its exact area (#435).
    func testARetainedParcelsAreaIsCorrected() throws {
        var form = try offered()
        form.areaTexts["p1"] = "15"
        XCTAssertEqual(try json(form.body), [
            "parcelIds": ["p1", "p2"],
            "parcels": [["parcelId": "p1", "treatedAreaHa": 1.5], ["parcelId": "p2", "treatedAreaHa": 1.2]],
        ])
        XCTAssertEqual(form.changes.map(\.label), ["Площ — Парцел 1"])

        form.areaTexts["p1"] = ""
        XCTAssertEqual(try json(form.body), [
            "parcelIds": ["p1", "p2"],
            "parcels": [["parcelId": "p1", "treatedAreaHa": 3], ["parcelId": "p2", "treatedAreaHa": 1.2]],
        ])
        XCTAssertEqual(form.changes.first?.after, Area(hectares: 3).text)
    }

    func testEveryParcelUntickedIsAWithdrawal() throws {
        var form = try offered()
        form.chosen = []
        XCTAssertEqual(form.problems().first, .noParcels)
        XCTAssertTrue(form.problems().first?.text.contains("«Изтрий»") == true)
    }

    func testAnAreaLargerThanTheParcelIsSaid() throws {
        var form = try offered()
        form.areaTexts["p1"] = "40"
        XCTAssertEqual(form.problems().first, .areaTooLarge("Парцел 1", Area(hectares: 3).text))
        form.areaTexts["p1"] = "0"
        XCTAssertEqual(form.problems().first, .area("Парцел 1"))
    }

    /// The entry's row after a parcel change: its count follows, and its total
    /// area waits for the journal rather than showing what it was.
    func testAParcelChangeLeavesTheRowsAreaToTheJournal() {
        let row = JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 2, totalAreaHa: 3.4, kind: "PRUNE")
        let saved = ActivityCorrection.Saved(definition: ActivityDefinition(
            treatmentGroupId: "tg_1", version: 4, kind: "PRUNE", occurredOn: "2026-09-08", harvestKg: nil,
            lines: [.init(parcelId: "p1", parcelName: nil)]), parcelsChanged: true)
        let after = row.applying(saved)
        XCTAssertEqual(after.parcelCount, 1)
        XCTAssertNil(after.totalAreaHa)
        XCTAssertEqual(row.applying(ActivityCorrection.Saved(definition: saved.definition)).totalAreaHa, 3.4,
                       "positive control: a day's correction keeps the area")
    }

    // MARK: - The trail

    /// An activity's own trail, with an activity's definition as `previous`:
    /// its day and total read back.
    func testAnActivityCorrectionSaysWhatItWas() async throws {
        let read = try await APIClient.shared.decode(Data(#"""
            {"treatmentGroupId":"tg_1","version":2,"corrections":[{"correctedAt":"2026-10-26T08:00:00.000Z",
             "correctedBy":null,"changedFields":["occurredOn","harvestKg"],
             "previous":{"treatmentGroupId":"tg_1","version":1,"kind":"HARVEST","occurredOn":"2026-09-08",
                         "harvestKg":4200,"parcelCount":1,"lines":[]}}]}
            """#.utf8), as: TreatmentCorrectionTrail.self)
        let correction = try XCTUnwrap(read.corrections.first)
        XCTAssertNil(correction.previous)
        XCTAssertEqual(correction.previousActivity?.activity, .harvest)
        XCTAssertEqual(TreatmentCorrection.was(correction).map(TreatmentCorrection.wasText),
                       ["Беше: \(BgDate.full(try day("2026-09-08")))", "Беше: \(TreatmentCheckView.kgText(4200))"])
    }

    /// A parcel change says what the set was, each parcel with its area.
    func testAnActivitysParcelCorrectionSaysWhatTheSetWas() async throws {
        let read = try await APIClient.shared.decode(Data(#"""
            {"treatmentGroupId":"tg_1","version":2,"corrections":[{"correctedAt":"2026-10-26T08:00:00.000Z",
             "correctedBy":null,"changedFields":["parcels"],
             "previous":{"treatmentGroupId":"tg_1","version":1,"kind":"PRUNE","occurredOn":"2026-09-08",
                         "harvestKg":null,"parcelCount":2,"lines":[
                           {"parcelId":"p1","parcelName":"Парцел 1","locationId":"b1","treatedAreaHa":1.2},
                           {"parcelId":"p2","parcelName":"Парцел 2","locationId":"b1","treatedAreaHa":null}]}}]}
            """#.utf8), as: TreatmentCorrectionTrail.self)
        let was = TreatmentCorrection.was(try XCTUnwrap(read.corrections.first))
        XCTAssertEqual(was.map(\.label), ["Парцели"])
        XCTAssertEqual(TreatmentCorrection.wasText(was[0]),
                       "Беше: Парцел 1 — \(Area(hectares: 1.2).text), Парцел 2 — \(TreatmentCorrection.wholeParcel)")
    }

    /// Positive control: a treatment's `previous` is still read as one, and
    /// never as an activity.
    func testATreatmentTrailIsReadAsBefore() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "treatment-corrections", withExtension: "json")
            ?? bundle.url(forResource: "Fixtures/treatment-corrections", withExtension: "json"))
        let read = try await APIClient.shared.decode(try Data(contentsOf: url), as: TreatmentCorrectionTrail.self)
        let correction = try XCTUnwrap(read.corrections.first)
        XCTAssertNotNil(correction.previous)
        XCTAssertNil(correction.previousActivity)
    }

    // MARK: - The server's words

    func testTheRefusalsAreBulgarian() {
        for code in ["ACTIVITY_NOT_FOUND", "ACTIVITY_MIXED_AUTHORSHIP", "NOT_AN_ACTIVITY",
                     "HARVEST_TOTAL_NOT_APPLICABLE", "TREATMENT_EDIT_NOT_PERMITTED"] {
            let text = UserMessage.bulgarian[code]
            XCTAssertNotNil(text, code)
            XCTAssertTrue(text?.hasSuffix(".") == true, code)
        }
        XCTAssertFalse(UserMessage.bulgarian["TREATMENT_EDIT_NOT_PERMITTED"]?.contains("третиране") ?? true,
                       "the shared refusal names a treatment to someone correcting a pruning")
    }
}
