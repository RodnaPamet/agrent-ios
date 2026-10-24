import XCTest
@testable import Agrent

/// «Коригирай» on a recorded treatment (#392; agri-saas #2283/#2287). Pure:
/// nothing here reaches the server.
@MainActor
final class TreatmentCorrectionTests: XCTestCase {

    private func definition(kind: String = "SPRAY", occurredOn: String? = "2026-09-16",
                            technique: String? = "boom", pest: String? = "Плевели",
                            quarantine: Int? = 30, phenophase: String? = nil) -> TreatmentDefinition {
        TreatmentDefinition(
            treatmentGroupId: "tg_1", version: 4, kind: kind, occurredOn: occurredOn,
            applicationTechnique: technique, targetNote: pest, productName: "Препарат А",
            pppRegistrationNo: nil, quarantinePeriodDays: quarantine, phenophase: phenophase,
            lines: [.init(parcelId: "p1", parcelName: "Парцел 1", treatedAreaHa: nil)])
    }

    private func draft(_ definition: TreatmentDefinition? = nil) -> TreatmentCorrection.Draft {
        TreatmentCorrection.Draft(definition ?? self.definition(), today: Self.today)
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
    func testAFertilisingCorrectsItsDateOnly() {
        var form = draft(definition(kind: "FERTILIZE", technique: nil, pest: nil, quarantine: nil))
        XCTAssertFalse(form.spraying)
        form.pestText = "Не се показва"
        XCTAssertEqual(form.changed, [])
        XCTAssertEqual(TreatmentCorrection.lockedNote(form.kind),
                       "Торът, дозата и парцелите не могат да се коригират все още.")
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
        let shown = row.applying(corrected)
        XCTAssertEqual(shown.quarantinePeriodDays, 14)
        XCTAssertEqual(shown.phenophase, "BBCH 31")
        XCTAssertEqual(shown.earliestHarvestOn, "2026-09-30")
        XCTAssertNil(row.applying(definition(quarantine: nil)).earliestHarvestOn, "no period, no date")
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
