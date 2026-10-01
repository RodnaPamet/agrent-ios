import XCTest
@testable import Agrent

/// The farm profile's write path — ported from agri-saas#1141/#1145, with the
/// full-replace trap of agri-saas#1176 as the thing every test here circles.
///
/// No network: the body, the validation and the after-save messages are pure
/// values, which is why they live in `FarmProfileEditing.swift` rather than in
/// the view. NOTHING here, or anywhere in the suite, sends the PUT.
final class FarmProfileEditTests: XCTestCase {

    /// The properties of `UpdateFarmProfileRequest` as agri-saas#1178
    /// documents them (13, none required; absent is left alone since #1181), which
    /// are the route's zod keys. Hard-coded rather than read from the spec at
    /// test time: the suite must not depend on another repository's branch.
    private let thirteen: Set<String> = [
        "producerName", "egn", "eik", "urn", "address", "municipality", "settlement",
        "agricultureDirectorateCity", "registrationPlace", "registrationEkatte",
        "odbhCity", "sizeHa", "grainProduced",
    ]

    private func profile(
        producerName: String? = "Иван Петров", egn: String? = "7501011234",
        eik: String? = "203912345", urn: String? = "1234567",
        address: String? = nil, sizeHa: Double? = 39.758,
        grain: [String] = ["пшеница", "царевица"]
    ) -> FarmProfile {
        FarmProfile(producerName: producerName, eik: eik, egn: egn, address: address,
                    settlement: "Плевен", municipality: "Плевен",
                    registrationPlace: nil, registrationEkatte: "56722",
                    odbhCity: nil, agricultureDirectorateCity: nil,
                    urn: urn, sizeHa: sizeHa, grainProduced: grain)
    }

    private func body(_ original: FarmProfile, _ edit: (inout FarmProfileDraft) -> Void = { _ in })
        throws -> FarmProfileUpdate
    {
        var draft = FarmProfileDraft(original)
        edit(&draft)
        switch FarmProfileUpdate.build(original: original, draft: draft) {
        case .success(let body): return body
        case .failure(let refusal):
            XCTFail("refused: \(refusal.problems.map(\.message))")
            throw CancellationError()
        }
    }

    private func problems(_ original: FarmProfile, _ edit: (inout FarmProfileDraft) -> Void)
        -> [FarmProfileUpdate.Problem]
    {
        var draft = FarmProfileDraft(original)
        edit(&draft)
        if case .failure(let refusal) = FarmProfileUpdate.build(original: original, draft: draft) {
            return refusal.problems
        }
        return []
    }

    private func json(_ update: FarmProfileUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(update)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The body: whole object, always

    /// agri-saas#1176. An absent key WAS nulled by the usecase until #1181
    /// made it "left alone"; all thirteen, every time, is correct under both
    /// and does not depend on which server build answers — including when
    /// every value is null, which is exactly when the synthesised `Encodable`
    /// would have dropped them all.
    func testTheBodyAlwaysCarriesAllThirteenKeys() throws {
        let full = try json(body(profile()))
        XCTAssertEqual(Set(full.keys), thirteen)

        let empty = FarmProfile(producerName: nil, eik: nil, egn: nil, address: nil,
                                settlement: nil, municipality: nil, registrationPlace: nil,
                                registrationEkatte: nil, odbhCity: nil,
                                agricultureDirectorateCity: nil, urn: nil, sizeHa: nil,
                                grainProduced: [])
        let blank = try json(body(empty) { $0[.producerName] = "Ново стопанство" })
        XCTAssertEqual(Set(blank.keys), thirteen, "nil fields were omitted — and omitted is erased")
        XCTAssertTrue(blank["egn"] is NSNull)
        XCTAssertTrue(blank["sizeHa"] is NSNull)
        XCTAssertEqual(blank["grainProduced"] as? [String], [])
    }

    /// Exactly the thirteen: unknown keys are stripped server-side, so an
    /// extra one would be a value the farmer believes saved and is not.
    func testTheBodyCarriesNothingElse() throws {
        XCTAssertEqual(Set(try json(body(profile())).keys).subtracting(thirteen), [])
    }

    /// Read-modify-write: editing ONE field sends the other twelve exactly as
    /// loaded — the case the wipe in #1176 was reproduced with.
    func testEditingOneFieldKeepsTheOtherTwelve() throws {
        let original = profile(grain: ["Пшеница", "царевица"])
        let sent = try body(original) { $0[.producerName] = "Мария Петрова" }

        XCTAssertEqual(sent.text[.producerName] ?? nil, "Мария Петрова")
        for field in FarmProfileText.allCases where field != .producerName {
            XCTAssertEqual(sent.text[field] ?? nil, original[keyPath: field.wire], "\(field)")
        }
        XCTAssertEqual(sent.sizeHa, 39.758, "an untouched size is resent as stored, not re-parsed")
        XCTAssertEqual(sent.grainProduced, ["Пшеница", "царевица"])
    }

    /// The ONE way to clear: the farmer emptied the field. Sent as null.
    func testAFieldIsClearedOnlyWhenTheFarmerClearedIt() throws {
        let sent = try body(profile()) { $0[.eik] = "" }
        XCTAssertNil(sent.text[.eik] ?? nil)
        XCTAssertTrue(try json(sent)["eik"] is NSNull)
        XCTAssertEqual(sent.text[.urn] ?? nil, "1234567", "a neighbour was cleared too")

        // Whitespace-only is empty to the server (trim → blank → null), so it
        // is a clear here as well rather than a value that silently becomes one.
        XCTAssertNil(try body(profile()) { $0[.eik] = "   " }.text[.eik] ?? nil)
    }

    func testAnEditedFieldIsTrimmed() throws {
        let sent = try body(profile()) { $0[.address] = "  ул. Дунав 3 \n" }
        XCTAssertEqual(sent.text[.address] ?? nil, "ул. Дунав 3")
    }

    /// Opening the editor and saving changes nothing.
    func testAnUntouchedDraftRebuildsTheLoadedProfile() throws {
        let original = profile()
        let sent = try body(original)
        for field in FarmProfileText.allCases {
            XCTAssertEqual(sent.text[field] ?? nil, original[keyPath: field.wire])
        }
        XCTAssertEqual(sent.sizeHa, original.sizeHa)
        XCTAssertEqual(sent.grainProduced, original.grainProduced)
    }

    /// sizeHa is a JSON NUMBER — not the decimal string the money fields use.
    func testTheSizeIsSentAsANumber() throws {
        let data = try JSONEncoder().encode(try body(profile()) { $0.sizeHa = "41,25" })
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"sizeHa\":41.25"), text)
    }

    // MARK: - Size

    func testTheSizeAcceptsABulgarianComma() {
        XCTAssertEqual(FarmProfileDraft.parseHectares("41,25"), .value(41.25))
        XCTAssertEqual(FarmProfileDraft.parseHectares("41.25"), .value(41.25))
        XCTAssertEqual(FarmProfileDraft.parseHectares(" 1 234,5 "), .value(1234.5))
        XCTAssertEqual(FarmProfileDraft.parseHectares("1\u{00A0}234,5"), .value(1234.5))
        XCTAssertEqual(FarmProfileDraft.parseHectares("12"), .value(12))
    }

    /// NULL AND ZERO ARE DIFFERENT CLAIMS. An empty box is "not declared";
    /// «0» is a declaration.
    func testZeroIsAValueAndBlankIsNot() throws {
        XCTAssertEqual(FarmProfileDraft.parseHectares("0"), .value(0))
        XCTAssertEqual(FarmProfileDraft.parseHectares("  "), .blank)
        XCTAssertEqual(try body(profile()) { $0.sizeHa = "0" }.sizeHa, 0)
        XCTAssertNil(try body(profile()) { $0.sizeHa = "" }.sizeHa)
    }

    /// The web sends an unparseable size as null — which CLEARS. Refused here.
    func testAnUnparseableSizeIsRefusedRatherThanClearingTheField() {
        XCTAssertEqual(FarmProfileDraft.parseHectares("около 40"), .notANumber)
        XCTAssertEqual(FarmProfileDraft.parseHectares("1,2,3"), .notANumber)
        XCTAssertEqual(FarmProfileDraft.parseHectares("1.234,5"), .notANumber)
        XCTAssertFalse(problems(profile()) { $0.sizeHa = "около 40" }.isEmpty)
    }

    /// `z.number().nonnegative().max(1_000_000)`.
    func testTheSizeBoundsAreTheRoutes() {
        XCTAssertEqual(FarmProfileDraft.parseHectares("-1"), .negative)
        XCTAssertEqual(FarmProfileDraft.parseHectares("-0,5"), .negative)
        XCTAssertEqual(FarmProfileDraft.parseHectares("1000000"), .value(1_000_000))
        XCTAssertEqual(FarmProfileDraft.parseHectares("1000000,1"), .tooLarge)
        XCTAssertFalse(problems(profile()) { $0.sizeHa = "-5" }.isEmpty)
        XCTAssertFalse(problems(profile()) { $0.sizeHa = "2000000" }.isEmpty)
    }

    /// The prefill: comma, no grouping, the column's three decimals.
    func testTheSizePrefillIsWhatTheParserReadsBack() {
        XCTAssertEqual(FarmProfileDraft.hectaresText(39.758), "39,758")
        XCTAssertEqual(FarmProfileDraft.hectaresText(12), "12")
        XCTAssertEqual(FarmProfileDraft.hectaresText(1234.5), "1234,5")
        for value in [0, 0.001, 39.758, 1234.5, 999_999.999] {
            XCTAssertEqual(FarmProfileDraft.parseHectares(FarmProfileDraft.hectaresText(value)),
                           .value(value), "\(value)")
        }
    }

    // MARK: - Text limits

    /// `UpdateFarmProfileSchema`'s `.max(n)`, per field, in UTF-16 units.
    func testTheTextLimitsAreTheRoutes() {
        XCTAssertEqual(FarmProfileText.producerName.maxLength, 300)
        XCTAssertEqual(FarmProfileText.egn.maxLength, 20)
        XCTAssertEqual(FarmProfileText.eik.maxLength, 20)
        XCTAssertEqual(FarmProfileText.urn.maxLength, 40)
        XCTAssertEqual(FarmProfileText.address.maxLength, 500)
        XCTAssertEqual(FarmProfileText.registrationEkatte.maxLength, 20)
        XCTAssertEqual(FarmProfileText.odbhCity.maxLength, 200)

        let found = problems(profile()) { $0[.producerName] = String(repeating: "я", count: 301) }
        XCTAssertEqual(found.map(\.field), [.producerName])
        XCTAssertTrue(problems(profile()) {
            $0[.producerName] = String(repeating: "я", count: 300)
        }.isEmpty)
    }

    /// No checksum, no digit count: the server takes any ЕГН up to 20
    /// characters, and so does this. A foreign national's ЛНЧ or a typo the
    /// farmer means to fix later must not be refused harder here than there.
    func testTheEGNIsNotValidatedHarderThanTheServer() {
        XCTAssertTrue(problems(profile()) { $0[.egn] = "12" }.isEmpty)
        XCTAssertTrue(problems(profile()) { $0[.egn] = "ЛНЧ 1234567890" }.isEmpty)
        XCTAssertTrue(problems(profile()) { $0[.eik] = "BG203912345" }.isEmpty)
    }

    // MARK: - Crops

    /// The web's comma split, then the usecase's fold: trim, drop blanks,
    /// de-duplicate case-insensitively keeping the FIRST spelling, and keep
    /// the farmer's order.
    func testCropsAreNormalisedAsTheWebAndServerDo() {
        XCTAssertEqual(
            FarmProfileDraft.normaliseCrops(
                ["Пшеница", " пшеница ", "", "Царевица, слънчоглед", "ПШЕНИЦА", "  "]),
            ["Пшеница", "Царевица", "слънчоглед"])
    }

    func testCropOrderIsNeverSorted() {
        XCTAssertEqual(FarmProfileDraft.normaliseCrops(["царевица", "ечемик", "али"]),
                       ["царевица", "ечемик", "али"])
    }

    /// The fold runs BEFORE sending: zod counts the raw array, so fifty crops
    /// and one duplicate must go as fifty rather than be refused as 51.
    func testDuplicatesDoNotCountTowardTheFiftyCropLimit() throws {
        let fifty = (1...50).map { "култура \($0)" }
        let sent = try body(profile()) { $0.crops = fifty + ["КУЛТУРА 1"] }
        XCTAssertEqual(sent.grainProduced.count, 50)

        XCTAssertFalse(problems(profile()) { $0.crops = fifty + ["още една"] }.isEmpty)
        XCTAssertFalse(problems(profile()) {
            $0.crops = [String(repeating: "а", count: 121)]
        }.isEmpty)
    }

    // MARK: - After the save

    func testASaveTheServerKeptAsSentSaysNothingMore() {
        var draft = FarmProfileDraft(profile())
        draft[.address] = "  ул. Дунав 3 "   // trimming alone is never reported
        let stored = profile(address: "ул. Дунав 3")
        XCTAssertEqual(FarmProfileSaveReport.notes(draft: draft, saved: stored), [])
    }

    func testADroppedDuplicateCropIsSaid() {
        var draft = FarmProfileDraft(profile())
        draft.crops = ["Пшеница", "пшеница", "царевица"]
        let notes = FarmProfileSaveReport.notes(
            draft: draft, saved: profile(grain: ["Пшеница", "царевица"]))
        XCTAssertEqual(notes, ["Премахнати като повторение: «пшеница»."])
    }

    /// A size the server did not keep — the usecase's negative-to-null branch
    /// in case the route's 400 ever stops guarding it.
    func testARefusedSizeIsSaid() {
        var draft = FarmProfileDraft(profile())
        draft.sizeHa = "41,25"
        let notes = FarmProfileSaveReport.notes(draft: draft, saved: profile(sizeHa: nil))
        XCTAssertEqual(notes, ["Размерът не беше приет и е празен."])
    }

    /// Decimal(12, 3): a fourth decimal is rounded by the database.
    func testARoundedSizeIsSaidAndFloatNoiseIsNot() {
        var draft = FarmProfileDraft(profile())
        draft.sizeHa = "41,2567"
        XCTAssertEqual(FarmProfileSaveReport.notes(draft: draft, saved: profile(sizeHa: 41.257)),
                       ["Размерът е записан като 41,257 ха."])

        draft.sizeHa = "0,3"
        XCTAssertEqual(FarmProfileSaveReport.notes(draft: draft, saved: profile(sizeHa: 0.1 + 0.2)),
                       [], "float noise was reported as a change")
    }

    /// `sanitizePlainText` strips tags, so «<b>Иван</b>» is stored as «Иван».
    func testASanitisedFieldIsSaidWithItsStoredValue() {
        var draft = FarmProfileDraft(profile())
        draft[.producerName] = "<b>Иван</b>"
        let notes = FarmProfileSaveReport.notes(draft: draft, saved: profile(producerName: "Иван"))
        XCTAssertEqual(notes, ["«\(FarmProfileText.producerName.label)» е записано като «Иван»."])
    }

    /// The ЕГН is never written into a note — notes are plain on-screen text
    /// and VoiceOver reads them.
    func testANoteAboutTheEGNNeverCarriesTheNumber() {
        var draft = FarmProfileDraft(profile())
        draft[.egn] = "<i>7501011234</i>"
        let notes = FarmProfileSaveReport.notes(draft: draft, saved: profile(egn: "7501011234"))
        XCTAssertEqual(notes.count, 1)
        XCTAssertFalse(notes.joined().contains("7501011234"))
    }

    // MARK: - Errors

    /// A zod refusal reaches the farmer in Bulgarian, not as the English
    /// "Invalid request payload" that `isHumanSentence` would pass through.
    func testAValidationRefusalIsBulgarian() {
        let text = UserMessage.httpText(status: 400, code: "VALIDATION_ERROR",
                                        message: "Invalid request payload")
        XCTAssertEqual(text, UserMessage.bulgarian["VALIDATION_ERROR"])
        XCTAssertFalse(text.contains("Invalid"))
    }

    /// A 403 on the save is the category sentence, not a retry prompt.
    func testAForbiddenSaveIsSaidAsSuch() {
        XCTAssertEqual(
            UserMessage.httpText(status: 403, code: "FORBIDDEN", message: "Forbidden"),
            "Нямате права за това действие.")
    }

    // MARK: - Who may edit

    /// The editor starts only from a profile the server SENT. The all-null
    /// stand-in a 403 produces would be written back as thirteen nulls.
    @MainActor
    func testTheEditorIsOfferedOnlyOverAProfileTheServerSent() {
        let store = AdminStore()
        XCTAssertFalse(store.canEditProfile, "editable before anything loaded")
        store.setProfileForTesting(profile(), editable: true)
        XCTAssertTrue(store.canEditProfile)
    }
}
