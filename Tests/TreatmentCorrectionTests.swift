import XCTest
@testable import Agrent

/// «Коригирай» on a recorded treatment (#392; agri-saas #2283/#2287). Pure:
/// nothing here reaches the server.
@MainActor
final class TreatmentCorrectionTests: XCTestCase {

    private func definition(kind: String = "SPRAY", occurredOn: String? = "2026-09-16",
                            technique: String? = "boom", pest: String? = "Плевели",
                            quarantine: Int? = 30, phenophase: String? = nil,
                            lines: [TreatmentDefinition.Line] = [
                                .init(parcelId: "p1", parcelName: "Парцел 1", treatedAreaHa: nil),
                            ]) -> TreatmentDefinition {
        TreatmentDefinition(
            treatmentGroupId: "tg_1", version: 4, kind: kind, occurredOn: occurredOn,
            applicationTechnique: technique, targetNote: pest, productItemId: "itm_a", productName: "Препарат А",
            pppRegistrationNo: nil, doseValue: Decimal(string: "0.15")!, doseUnitId: "u_l",
            doseUnitSymbol: nil, waterRateValue: nil, waterRateUnitSymbol: nil,
            quarantinePeriodDays: quarantine, phenophase: phenophase, lines: lines)
    }

    private func draft(_ definition: TreatmentDefinition? = nil) -> TreatmentCorrection.Draft {
        TreatmentCorrection.Draft(definition ?? self.definition(), unitSymbol: "л/дка", today: Self.today)
    }

    /// The farm's catalogue as `/items` serves it: two products and a
    /// fertiliser.
    private func catalogue() throws -> [InputItem] {
        let json = #"[{"id":"itm_a","name":"Препарат А","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u"},{"id":"itm_b","name":"Препарат Б","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u"},{"id":"itm_t","name":"Тор В","category":"FERTILIZER","defaultUnit":null,"createdByUserId":"u"}]"#
        return try JSONDecoder().decode([InputItem].self, from: Data(json.utf8))
    }

    private static let today = BgDate.parseISODay("2026-10-24")!

    private func json(_ body: TreatmentCorrection.Body) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any])
    }

    // MARK: - What goes out

    /// The form as it opened changes nothing, so nothing can be saved, and
    /// nothing would go out.
    func testAnUntouchedFormChangesNothing() throws {
        let form = draft()
        XCTAssertEqual(form.changed, [])
        XCTAssertEqual(form.problems(now: Self.today), [.nothingChanged])
        XCTAssertEqual(try json(form.body).count, 0)
    }

    /// Only what changed is sent. An omitted field is left as it is on the
    /// server, which is what keeps the rest of the record safe.
    func testOnlyTheChangedFieldGoesOut() throws {
        var form = draft()
        form.phenophaseText = "  BBCH 31 "
        let sent = try json(form.body)
        XCTAssertEqual(sent.keys.sorted(), ["phenophase"])
        XCTAssertEqual(sent["phenophase"] as? String, "BBCH 31", "trimmed")
        XCTAssertEqual(form.problems(now: Self.today), [])
    }

    /// A field cleared goes out as an explicit null. Left out, the server
    /// would read it as "unchanged" and keep the value.
    func testAClearedFieldIsSentAsNull() throws {
        var form = draft(definition(phenophase: "BBCH 12"))
        form.phenophaseText = ""
        let sent = try json(form.body)
        XCTAssertEqual(sent.keys.sorted(), ["phenophase"])
        XCTAssertTrue(sent["phenophase"] is NSNull, "\(sent)")
    }

    func testTheDateGoesOutAsTheFarmDay() throws {
        var form = draft()
        form.date = BgDate.parseISODay("2026-09-17")!
        XCTAssertEqual(try json(form.body)["occurredOn"] as? String, "2026-09-17")
        XCTAssertEqual(form.changes.first?.before, BgDate.full(BgDate.parseISODay("2026-09-16")!))
    }

    // MARK: - The technique

    /// A stored value outside the seven is kept, shown, and not rewritten
    /// by an untouched picker. `Boom` is the same choice as `boom`.
    func testTheTechniqueIsKeptAsRecorded() {
        let unknown = draft(definition(technique: "Dron"))
        XCTAssertEqual(unknown.technique, "Dron")
        XCTAssertEqual(unknown.techniqueOptions.first, "Dron", "the recorded value is a choice")
        XCTAssertEqual(unknown.changed, [])

        let cased = draft(definition(technique: "Boom"))
        XCTAssertEqual(cased.technique, "boom")
        XCTAssertEqual(cased.changed, [], "a case difference is no change")
        XCTAssertFalse(cased.techniqueOptions.contains("Boom"), "and no second «Щангова пръскачка»")

        let none = draft(definition(technique: nil))
        XCTAssertEqual(none.techniqueOptions.first, .some(nil), "«—» while nothing was recorded")
    }

    // MARK: - What can't be saved

    /// A required field that was filled may not be emptied. One a record
    /// never captured may stay empty: the correction doesn't demand what the
    /// day didn't record.
    func testARequiredFieldMayNotBeEmptied() {
        var form = draft()
        form.pestText = " "
        XCTAssertEqual(form.problems(now: Self.today).first, .pestMissing)
        form.pestText = "Плевели"
        form.quarantineText = ""
        XCTAssertEqual(form.problems(now: Self.today).first, .quarantineMissing)

        var old = draft(definition(pest: nil, quarantine: nil))
        old.phenophaseText = "BBCH 31"
        XCTAssertEqual(old.problems(now: Self.today), [], "positive control: never captured, still empty")
    }

    func testThePeriodIsWholeDaysTheServerTakes() {
        var form = draft()
        for text in ["abc", "-1", "366", "2,5"] {
            form.quarantineText = text
            XCTAssertEqual(form.problems(now: Self.today).first, .quarantineInvalid, text)
            XCTAssertFalse(form.changed.contains(.quarantinePeriodDays), "\(text) is not a change")
        }
        form.quarantineText = "365"
        XCTAssertEqual(form.problems(now: Self.today), [])
        XCTAssertEqual(form.changed, [.quarantinePeriodDays])
    }

    func testTheDateIsTodayOrEarlier() {
        var form = draft()
        form.date = BgDate.parseISODay("2026-10-25")!
        XCTAssertEqual(form.problems(now: Self.today).first, .futureDate)
    }

    /// A fertilising has no pest, stage, period or technique on its form, so
    /// none of them can change.
    func testAFertilisingHasNoSprayingFields() {
        var form = draft(definition(kind: "FERTILIZE", technique: nil, pest: nil, quarantine: nil))
        XCTAssertFalse(form.spraying)
        form.pestText = "Не се показва"
        form.quarantineText = "abc"
        XCTAssertEqual(form.changed, [])
        XCTAssertEqual(form.problems(now: Self.today), [.nothingChanged])
    }

    // MARK: - The product, the dose and the areas (agri-saas #2293)

    /// By id, and only one the farm has: a correction can't create a product.
    func testTheProductIsChosenFromTheCatalogue() throws {
        var form = draft()
        form.productText = "Препарат Б"
        form.resolve(in: nil)
        XCTAssertEqual(form.problems(now: Self.today).first, .product("Каталогът на стопанството още се зарежда."))
        form.resolve(in: try catalogue())
        XCTAssertEqual(form.changed, [.productItemId])
        XCTAssertEqual(try json(form.body)["productItemId"] as? String, "itm_b")
        XCTAssertEqual(form.changes.first?.after, "Препарат Б")

        form.productText = "Нещо ново"
        form.resolve(in: try catalogue())
        XCTAssertEqual(form.changed, [], "a name the farm hasn't got is no change")
        XCTAssertTrue(form.problems(now: Self.today).first?.text.contains("не е в каталога") == true)

        form.productText = "препарат а"
        form.resolve(in: try catalogue())
        XCTAssertEqual(form.changed, [], "the recorded product, typed in another case")
        XCTAssertEqual(form.problems(now: Self.today), [.nothingChanged])
    }

    func testAFertilisingTakesAFertiliser() throws {
        var form = draft(definition(kind: "FERTILIZE", technique: nil, pest: nil, quarantine: nil))
        form.productText = "Препарат Б"
        form.resolve(in: try catalogue())
        XCTAssertEqual(form.problems(now: Self.today).first?.text,
                       "«Препарат Б» не е тор. Изберете тор от каталога на стопанството.")
        form.productText = "Тор В"
        form.resolve(in: try catalogue())
        XCTAssertEqual(form.changed, [.productItemId])
    }

    /// The value and the unit are one line on «Проверка», and each goes out
    /// only when it moved.
    func testTheDoseAndItsUnit() throws {
        var form = draft()
        XCTAssertEqual(form.doseText, "0,15")
        form.doseText = "0,150"
        XCTAssertEqual(form.changed, [], "the same number, written otherwise")
        form.doseText = "0,2"
        form.doseUnit = .init(id: "u_ml", symbol: "мл/дка")
        let sent = try json(form.body)
        XCTAssertEqual(sent.keys.sorted(), ["doseUnitId", "doseValue"])
        XCTAssertEqual((sent["doseValue"] as? NSNumber)?.doubleValue ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(form.changes.map(\.label), ["Доза"])
        XCTAssertEqual(form.changes.first?.before, "0,15 л/дка")
        XCTAssertEqual(form.changes.first?.after, "0,2 мл/дка")
        form.doseText = "0"
        XCTAssertEqual(form.problems(now: Self.today).first, .doseNotPositive)
        form.doseText = ""
        XCTAssertEqual(form.problems(now: Self.today).first, .doseMissing)
    }

    /// The recorded unit is a choice even when the farm's list doesn't hold
    /// it, so the picker can show it chosen.
    func testTheRecordedUnitIsAChoice() throws {
        let units = try JSONDecoder().decode([Agrent.Unit].self, from: Data(#"[{"id":"u_ml","key":"ml_per_dca","name":null,"symbol":"мл/дка","measure":"RATE"}]"#.utf8))
        let form = draft()
        XCTAssertEqual(form.unitOptions(units).map(\.id), ["u_l", "u_ml"])
    }

    /// One area moved: every parcel goes out, the set as recorded, a whole
    /// parcel as an explicit null.
    func testAnAreaChangeSendsTheWholeSet() throws {
        var form = draft(definition(lines: [
            .init(parcelId: "p1", parcelName: "Парцел 1", treatedAreaHa: nil),
            .init(parcelId: "p2", parcelName: "Парцел 2", treatedAreaHa: 1.2),
        ]))
        XCTAssertEqual(form.areaTexts["p2"], Area(hectares: 1.2).number, "shown in decares")
        XCTAssertEqual(form.changed, [])
        form.areaTexts["p1"] = "5"
        let sent = try json(form.body)
        XCTAssertEqual(sent.keys.sorted(), ["parcels"])
        let parcels = try XCTUnwrap(sent["parcels"] as? [[String: Any]])
        XCTAssertEqual(parcels.map { $0["parcelId"] as? String }, ["p1", "p2"])
        XCTAssertEqual((parcels[0]["treatedAreaHa"] as? NSNumber)?.doubleValue ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual((parcels[1]["treatedAreaHa"] as? NSNumber)?.doubleValue ?? 0, 1.2, accuracy: 1e-9)
        XCTAssertEqual(form.changes.map(\.label), ["Площ — Парцел 1"])
        XCTAssertEqual(form.changes.first?.before, TreatmentCorrection.wholeParcel)

        form.areaTexts["p1"] = nil
        form.areaTexts["p2"] = nil
        let whole = try XCTUnwrap(try json(form.body)["parcels"] as? [[String: Any]])
        XCTAssertTrue(whole[1]["treatedAreaHa"] is NSNull, "the whole parcel again, said as null")

        form.areaTexts["p2"] = "0"
        XCTAssertEqual(form.problems(now: Self.today).first, .area("Парцел 2"))
    }

    // MARK: - «Проверка»

    /// Before and after, in words; nil is an empty field, which the row says
    /// as «няма» aloud.
    func testEachChangeIsReadBack() {
        var form = draft()
        form.quarantineText = "14"
        form.phenophaseText = "BBCH 31"
        XCTAssertEqual(form.changes.map(\.label), ["Фенофаза/BBCH", "Карантинен срок"], "the form's order")
        XCTAssertEqual(form.changes[0].before, nil)
        XCTAssertEqual(form.changes[0].after, "BBCH 31")
        XCTAssertEqual(form.changes[1].before, Plural.bg(30, "ден", "дни"))
        XCTAssertEqual(form.changes[1].after, Plural.bg(14, "ден", "дни"))
    }

    // MARK: - After the save

    /// The entry's screen shows the correction at once, the earliest harvest
    /// worked out again from the day and the period.
    func testTheRowTakesTheCorrection() {
        let row = JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 1, earliestHarvestOn: "2026-10-16",
                                   targetNote: "Плевели", quarantinePeriodDays: 30)
        let corrected = definition(quarantine: 14, phenophase: "BBCH 31")
        let shown = row.applying(.init(definition: corrected, unitSymbol: "л/дка", areaChanged: false))
        XCTAssertEqual(shown.quarantinePeriodDays, 14)
        XCTAssertEqual(shown.phenophase, "BBCH 31")
        XCTAssertEqual(shown.earliestHarvestOn, "2026-09-30")
        XCTAssertEqual(shown.doseText, "0,15 л/дка")
        XCTAssertEqual(shown.foldedProduct, "Препарат А")
        XCTAssertNil(row.applying(.init(definition: definition(quarantine: nil), unitSymbol: nil, areaChanged: false))
            .earliestHarvestOn, "no period, no date")
        let area = JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 1, totalAreaHa: 4.2)
        XCTAssertEqual(area.applying(.init(definition: corrected, unitSymbol: nil, areaChanged: false)).totalAreaHa, 4.2)
        XCTAssertNil(area.applying(.init(definition: corrected, unitSymbol: nil, areaChanged: true)).totalAreaHa,
                     "a moved area leaves the total unknown, not as it was")
    }

    // MARK: - Who, and what is said

    /// The row's own `mayCorrect`, never `mayDelete`: the two may part
    /// (agri-saas #2280). An absent flag (a cached page) is not a refusal.
    func testItIsOfferedWhereTheRowAllows() {
        func entry(correct: Bool?, delete: Bool?) -> LogEntry {
            LogEntry(id: "e", type: .inputApplication, status: .done, title: "Препарат А", occurredAt: nil,
                     treatment: JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 1,
                                                 mayDelete: delete, mayCorrect: correct))
        }
        func me(canWrite: Bool) -> CurrentUser {
            CurrentUser(id: "u", name: nil, email: nil, role: nil,
                        permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: false))
        }
        let writer = me(canWrite: true)
        XCTAssertTrue(TreatmentCorrection.offered(entry(correct: true, delete: true), to: writer))
        XCTAssertTrue(TreatmentCorrection.offered(entry(correct: nil, delete: nil), to: writer))
        XCTAssertFalse(TreatmentCorrection.offered(entry(correct: false, delete: true), to: writer),
                       "may delete, may not correct: the correction's own flag decides")
        XCTAssertTrue(TreatmentCorrection.offered(entry(correct: true, delete: false), to: writer),
                      "deletion narrowed: still correctable")
        XCTAssertTrue(TreatmentCorrection.offered(entry(correct: nil, delete: false), to: writer),
                      "no fallback to mayDelete")
        XCTAssertFalse(TreatmentCorrection.offered(entry(correct: true, delete: true), to: me(canWrite: false)))
    }

    /// One sentence for both refusals since agri-saas #2292: it names
    /// correcting and removing, and sends nobody to an administrator, who
    /// is bound too.
    func testAMixedAuthorshipRefusalNamesBoth() {
        let mixed = UserMessage.text(for: APIClient.APIError.http(status: 409, code: "TREATMENT_MIXED_AUTHORSHIP", message: nil))
        XCTAssertTrue(mixed.contains("коригирано или премахнато"), mixed)
        XCTAssertFalse(mixed.contains("Обърнете се към администратор"), mixed)
        let refused = APIClient.APIError.http(status: 403, code: "TREATMENT_EDIT_NOT_PERMITTED", message: nil)
        XCTAssertTrue(UserMessage.text(for: refused).hasSuffix("може да го коригира."))
    }

    // MARK: - «Корекции» (agri-saas #2292)

    private func trail(_ json: String) async throws -> TreatmentCorrectionTrail {
        try await APIClient.shared.decode(Data(json.utf8), as: TreatmentCorrectionTrail.self)
    }

    private func previousJSON(pest: String = "Плевели", quarantine: String = "21") -> String {
        #"{"treatmentGroupId":"tg_1","version":1,"kind":"SPRAY","occurredOn":"2026-09-16","title":"А","applicationTechnique":"boom","targetNote":"\#(pest)","productItemId":"i","productName":"Препарат А","pppRegistrationNo":null,"doseValue":1,"doseUnitId":"u","waterRateValue":null,"waterRateUnitId":null,"quarantinePeriodDays":\#(quarantine),"phenophase":null,"lines":[]}"#
    }

    /// Each field with what it was, in the form's order; the dose, whose
    /// unit the definition names by id, only as changed.
    func testACorrectionSaysWhatEachFieldWas() async throws {
        let read = try await trail(#"{"treatmentGroupId":"tg_1","version":2,"corrections":[{"correctedAt":"2026-10-24T18:40:00.000Z","correctedBy":"Иван Иванов","changedFields":["quarantinePeriodDays","targetNote","doseValue","doseUnitId","somethingNew"],"previous":"# + previousJSON() + "}]}")
        let entry = try XCTUnwrap(read.corrections.first)
        let was = TreatmentCorrection.was(entry)
        XCTAssertEqual(was.map(\.label), ["Вредител", "Доза", "Карантинен срок"],
                       "the form's order; the dose once; an unknown field left out")
        XCTAssertEqual(TreatmentCorrection.wasText(was[0]), "Беше: Плевели")
        XCTAssertEqual(TreatmentCorrection.wasText(was[1]), "Променено")
        XCTAssertEqual(TreatmentCorrection.wasText(was[2]), "Беше: \(Plural.bg(21, "ден", "дни"))")
        let line = TreatmentCorrection.correctedLine(entry)
        XCTAssertTrue(line.hasPrefix("Коригирано на \(BgDate.full(entry.correctedAt)) в "), line)
        XCTAssertTrue(line.hasSuffix(" от Иван Иванов"), line)
        XCTAssertTrue(TreatmentCorrection.spoken(entry).contains("Вредител: беше Плевели"))
    }

    /// A rate is said with its unit (agri-saas #2298), or only named: a
    /// `previous` stored before the symbol existed has none.
    func testADoseCorrectionSaysWhatTheDoseWas() async throws {
        let withUnit = previousJSON().replacingOccurrences(
            of: #""doseUnitId":"u","#, with: #""doseUnitId":"u","doseUnitSymbol":"л/дка","waterRateUnitSymbol":null,"#)
        let read = try await trail(#"{"treatmentGroupId":"tg_1","version":3,"corrections":[{"correctedAt":"2026-10-25T08:00:00.000Z","correctedBy":null,"changedFields":["doseValue","waterRateValue","waterRateUnitId"],"previous":"# + withUnit + #"},{"correctedAt":"2026-10-24T08:00:00.000Z","correctedBy":null,"changedFields":["doseValue"],"previous":"# + previousJSON() + "}]}")
        let newer = TreatmentCorrection.was(read.corrections[0])
        XCTAssertEqual(newer.map(TreatmentCorrection.wasText), ["Беше: 1 л/дка", "Беше: —"],
                       "the dose with its unit; no water rate before")
        XCTAssertEqual(TreatmentCorrection.was(read.corrections[1]).map(TreatmentCorrection.wasText), ["Променено"],
                       "stored before the symbol: named only")
    }

    /// The form takes the definition's own symbol over the row's.
    func testTheFormTakesTheDefinitionsUnitSymbol() async throws {
        let json = previousJSON().replacingOccurrences(of: #""doseUnitId":"u","#,
                                                       with: #""doseUnitId":"u","doseUnitSymbol":"кг/дка","#)
        let definition = try await APIClient.shared.decode(Data(json.utf8), as: TreatmentDefinition.self)
        let form = TreatmentCorrection.Draft(definition, unitSymbol: "л/дка", today: Self.today)
        XCTAssertEqual(form.doseUnit.symbol, "кг/дка")
        XCTAssertEqual(TreatmentCorrection.Draft(self.definition(), unitSymbol: "л/дка").doseUnit.symbol, "л/дка",
                       "the row's, where the definition has none")
    }

    /// The areas as they were, every parcel, from the definition's own lines.
    func testAnAreaCorrectionSaysWhatTheAreasWere() async throws {
        let previous = previousJSON().replacingOccurrences(
            of: #""lines":[]"#,
            with: #""lines":[{"parcelId":"p1","parcelName":"Парцел 1","locationId":null,"treatedAreaHa":null},{"parcelId":"p2","parcelName":"Парцел 2","locationId":null,"treatedAreaHa":1.2}]"#)
        let read = try await trail(#"{"treatmentGroupId":"tg_1","version":2,"corrections":[{"correctedAt":"2026-10-24T18:40:00.000Z","correctedBy":null,"changedFields":["treatedAreaHa"],"previous":"# + previous + "}]}")
        let was = TreatmentCorrection.was(try XCTUnwrap(read.corrections.first))
        XCTAssertEqual(was.map(\.label), ["Третирана площ"])
        XCTAssertEqual(TreatmentCorrection.wasText(was[0]),
                       "Беше: Парцел 1 — \(TreatmentCorrection.wholeParcel), Парцел 2 — \(Area(hectares: 1.2).text)")
    }

    /// No name, no «от …», never an id. An unreadable `previous` costs the
    /// "was" values, not the correction or the rest of the trail.
    func testATrailReadsWithoutANameOrAPreviousDefinition() async throws {
        let read = try await trail(#"{"treatmentGroupId":"tg_1","version":3,"corrections":[{"correctedAt":"2026-10-24T18:40:00.000Z","correctedBy":null,"changedFields":["phenophase"],"previous":{"shape":"unknown"}},{"correctedAt":"2026-10-23T08:00:00.000Z","correctedBy":"  ","changedFields":["phenophase"],"previous":null}]}"#)
        XCTAssertEqual(read.corrections.count, 2)
        for entry in read.corrections {
            XCTAssertFalse(TreatmentCorrection.correctedLine(entry).contains(" от "))
            XCTAssertEqual(TreatmentCorrection.was(entry).map(TreatmentCorrection.wasText), ["Променено"])
        }
    }

    /// The fixture the screenshot shows, read as the screen reads it.
    func testTheFixtureTrail() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "treatment-corrections", withExtension: "json")
            ?? bundle.url(forResource: "Fixtures/treatment-corrections", withExtension: "json"))
        let read = try await APIClient.shared.decode(try Data(contentsOf: url), as: TreatmentCorrectionTrail.self)
        let was = TreatmentCorrection.was(try XCTUnwrap(read.corrections.first))
        XCTAssertEqual(was.map(TreatmentCorrection.wasText), ["Беше: Плевели", "Беше: \(Plural.bg(21, "ден", "дни"))"])
    }
}
