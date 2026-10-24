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

    /// The withdrawal's rule, from the row: never a probe of the write-gated
    /// read. An absent flag (a cached page) is not a refusal.
    func testItIsOfferedWhereTheRowAllows() {
        func entry(_ mayDelete: Bool?) -> LogEntry {
            LogEntry(id: "e", type: .inputApplication, status: .done, title: "Препарат А", occurredAt: nil,
                     treatment: JournalTreatment(treatmentGroupId: "tg_1", parcelCount: 1, mayDelete: mayDelete))
        }
        func me(canWrite: Bool) -> CurrentUser {
            CurrentUser(id: "u", name: nil, email: nil, role: nil,
                        permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: false))
        }
        XCTAssertTrue(TreatmentCorrection.offered(entry(true), to: me(canWrite: true)))
        XCTAssertTrue(TreatmentCorrection.offered(entry(nil), to: me(canWrite: true)))
        XCTAssertFalse(TreatmentCorrection.offered(entry(false), to: me(canWrite: true)))
        XCTAssertFalse(TreatmentCorrection.offered(entry(true), to: me(canWrite: false)))
    }

    /// The server's mixed-authorship sentence is about deleting; here it's
    /// said about correcting. Every other refusal is the server's own.
    func testAMixedAuthorshipRefusalIsAboutCorrecting() {
        let mixed = APIClient.APIError.http(status: 409, code: "TREATMENT_MIXED_AUTHORSHIP", message: nil)
        XCTAssertTrue(TreatmentCorrection.text(for: mixed).contains("не може да се коригира"))
        let refused = APIClient.APIError.http(status: 403, code: "TREATMENT_EDIT_NOT_PERMITTED", message: nil)
        XCTAssertEqual(TreatmentCorrection.text(for: refused), UserMessage.text(for: refused))
        XCTAssertTrue(UserMessage.text(for: refused).hasSuffix("може да го коригира."))
    }
}
