import XCTest
@testable import Agrent

/// The farm profile's optimistic lock — agri-saas#1184, client side.
///
/// Four claims, each one a way the lock could be present on the wire and
/// still protect nothing:
///
///   1. `version` decodes, and 0 (the "no row yet" sentinel) is a version.
///   2. The save sends the version the DRAFT WAS BUILT OVER, as a bare
///      integer — not the store's latest, not a tag, not nothing.
///   3. A 409 reads its versions from `error.details` and is NOT a save.
///   4. After a save, the NEXT save carries the version the server returned.
///
/// NOTHING HERE SENDS THE PUT. The store's network is two injected closures,
/// because there is no URLProtocol seam in `Tests/` and every one of the four
/// is decided above the wire anyway.
@MainActor
final class FarmProfileLockTests: XCTestCase {

    private func profile(version: Int?, municipality: String? = "Плевен",
                         egn: String? = "7501011234", sizeHa: Double? = 39.758,
                         grain: [String] = ["пшеница"]) -> FarmProfile {
        FarmProfile(producerName: "Иван Петров", eik: "203912345", egn: egn,
                    address: nil, settlement: "Плевен", municipality: municipality,
                    registrationPlace: nil, registrationEkatte: "56722",
                    odbhCity: nil, agricultureDirectorateCity: nil,
                    urn: "1234567", sizeHa: sizeHa, grainProduced: grain,
                    version: version)
    }

    private func build(_ original: FarmProfile,
                       _ edit: (inout FarmProfileDraft) -> Void) throws -> FarmProfileUpdate {
        var draft = FarmProfileDraft(original)
        edit(&draft)
        return try FarmProfileUpdate.build(original: original, draft: draft).get()
    }

    /// Records what the store handed to the network, and answers as told.
    private final class Wire {
        var sent: [FarmProfileUpdate] = []
        var answer: (FarmProfileUpdate) throws -> FarmProfile
        init(_ answer: @escaping (FarmProfileUpdate) throws -> FarmProfile) { self.answer = answer }
    }

    private func store(_ wire: Wire, fetch: @escaping () throws -> FarmProfile = {
        throw URLError(.notConnectedToInternet)
    }) -> AdminStore {
        AdminStore(
            sendProfile: { body in wire.sent.append(body); return try wire.answer(body) },
            fetchProfile: { try fetch() })
    }

    // MARK: - 1. Decoding

    private let fields = """
    "producerName":null,"egn":null,"eik":null,"urn":null,"address":null,
    "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
    "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
    "sizeHa":null,"grainProduced":[]
    """

    private func decode(_ json: String) async throws -> FarmProfile {
        try await AdminAPI.decodeFarmProfile(from: Data(json.utf8))
    }

    func testTheVersionDecodes() async throws {
        let p = try await decode("{\(fields),\"version\":7}")
        XCTAssertEqual(p.version, 7)
    }

    /// 0 is the all-null "no row yet" answer, and it is SENT — `If-Match: 0`
    /// means "create". Collapsing it to nil would make the first save
    /// unguarded, and two first saves would race exactly as before #1184.
    func testVersionZeroIsAVersionNotAnAbsence() async throws {
        let p = try await decode("{\(fields),\"version\":0}")
        XCTAssertEqual(p.version, 0)
        XCTAssertEqual(try build(p) { $0[.urn] = "1" }.expectedVersion, 0)
    }

    /// A server without #1184 omits it. The screen must still load — the
    /// tolerance rule — and the save then goes unguarded, as the route
    /// documents for an absent header, rather than inventing a 0.
    func testAnAbsentVersionDecodesAsNilAndSendsNoPrecondition() async throws {
        let p = try await decode("{\(fields)}")
        XCTAssertNil(p.version)
        XCTAssertNil(try build(p) { $0[.urn] = "1" }.expectedVersion)
    }

    // MARK: - 2. What goes out as If-Match

    /// The BARE integer. The route also takes a strong tag but 400s a weak
    /// one, and the journal and field-operations routes take only this.
    func testIfMatchIsTheBareInteger() {
        XCTAssertEqual(APIClient.ifMatch(5), "5")
        XCTAssertEqual(APIClient.ifMatch(0), "0")
        XCTAssertFalse(APIClient.ifMatch(12).contains("\""))
        XCTAssertFalse(APIClient.ifMatch(12).hasPrefix("W/"))
    }

    /// The version rides on the body's builder, NOT in the JSON: the body
    /// schema has no `version`, and the twelve keys stay twelve (`eik` is
    /// never sent — agri-saas#1352).
    func testTheBuiltBodyCarriesTheLoadedVersionButDoesNotEncodeIt() throws {
        let body = try build(profile(version: 3)) { $0[.municipality] = "Ловеч" }
        XCTAssertEqual(body.expectedVersion, 3)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(json["version"])
        XCTAssertNil(json["eik"])
        XCTAssertEqual(json.count, 12)
    }

    /// THE LOST UPDATE THIS PREVENTS. The store's copy moves under an open
    /// sheet (pull-to-refresh). The save must still send the version the
    /// edits were made OVER — the newer one would pass the lock and write
    /// stale values over a change the farmer never saw.
    func testTheSaveSendsTheVersionTheDraftWasBuiltOverNotTheStoresLatest() async throws {
        let wire = Wire { _ in self.profile(version: 9) }
        let s = store(wire)
        let opened = profile(version: 3)
        s.setProfileForTesting(opened, editable: true)
        let body = try build(opened) { $0[.municipality] = "Ловеч" }

        s.setProfileForTesting(profile(version: 5), editable: true) // refreshed behind the sheet
        try await s.saveProfile(body, typed: FarmProfileDraft(opened))

        XCTAssertEqual(wire.sent.map(\.expectedVersion), [3])
    }

    // MARK: - 3. The 409

    /// The spec's own shape (`FarmProfileStaleDataError`): versions NESTED
    /// under `error.details`. Read from the root they are nil, and a keep-
    /// mine retry would then go out with no precondition (#922 on the web).
    func testA409ReadsItsVersionsFromErrorDetails() {
        let body = #"""
        {"error":{"code":"STALE_DATA","message":"The farm profile changed while you were editing it.",
         "requestId":"req_1","details":{"currentVersion":4,"expectedVersion":3}}}
        """#
        guard case .conflict(let current, let expected) = APIClient.conflict(from: Data(body.utf8))
        else { return XCTFail("a 409 did not become .conflict") }
        XCTAssertEqual(current, 4)
        XCTAssertEqual(expected, 3)

        let atRoot = #"{"currentVersion":4,"expectedVersion":3,"error":{"code":"STALE_DATA"}}"#
        guard case .conflict(let rootCurrent, _) = APIClient.conflict(from: Data(atRoot.utf8))
        else { return XCTFail("a 409 did not become .conflict") }
        XCTAssertNil(rootCurrent, "read the versions off the body root")
    }

    /// `currentVersion: 0` — the row is gone. Still a conflict, never a save.
    func testA409ForAVanishedRowIsStillAConflict() {
        let body = #"{"error":{"code":"STALE_DATA","message":"gone","details":{"currentVersion":0,"expectedVersion":3}}}"#
        guard case .conflict(let current, _) = APIClient.conflict(from: Data(body.utf8))
        else { return XCTFail("a 409 did not become .conflict") }
        XCTAssertEqual(current, 0)
    }

    /// A 409 reaches the sheet as `.conflict` and changes NOTHING on screen:
    /// no profile swap, no «записан» note, one request — no silent retry.
    func testAConflictIsNotASaveAndIsNotRetried() async throws {
        let wire = Wire { _ in
            throw APIClient.APIError.conflict(currentVersion: 4, expectedVersion: 3)
        }
        let s = store(wire)
        let opened = profile(version: 3)
        s.setProfileForTesting(opened, editable: true)
        let body = try build(opened) { $0[.municipality] = "Ловеч" }

        do {
            try await s.saveProfile(body, typed: FarmProfileDraft(opened))
            XCTFail("a 409 was treated as a save")
        } catch APIClient.APIError.conflict(let current, let expected) {
            XCTAssertEqual(current, 4)
            XCTAssertEqual(expected, 3)
        }
        XCTAssertEqual(wire.sent.count, 1, "the conflict was retried")
        XCTAssertEqual(s.profile.value, opened)
        XCTAssertNil(s.lastSaveNotes)
    }

    /// The conflict sentence is Bulgarian and says the edits were NOT saved.
    func testTheConflictMessageSaysNothingWasSaved() {
        XCTAssertTrue(FarmProfileConflict.message.contains("не са записани"))
        XCTAssertEqual(FarmProfileConflict.reload, "Презареди")
    }

    // MARK: - 4. The next save

    /// The response's version is the next `If-Match` — no re-GET. Two saves
    /// in a row from one session must not 409 against themselves.
    func testTheNextSaveCarriesTheVersionTheServerReturned() async throws {
        var next = 4
        let wire = Wire { body in
            defer { next += 1 }
            return self.profile(version: next, municipality: body.text[.municipality] ?? nil)
        }
        let s = store(wire)
        s.setProfileForTesting(profile(version: 3), editable: true)

        let first = try XCTUnwrap(s.profile.value)
        try await s.saveProfile(try build(first) { $0[.municipality] = "Ловеч" },
                                typed: FarmProfileDraft(first))
        XCTAssertEqual(s.profile.value?.version, 4)

        // The next editor opens on what the store now holds.
        let second = try XCTUnwrap(s.profile.value)
        try await s.saveProfile(try build(second) { $0[.municipality] = "Русе" },
                                typed: FarmProfileDraft(second))

        XCTAssertEqual(wire.sent.map(\.expectedVersion), [3, 4])
        XCTAssertEqual(s.profile.value?.version, 5)
    }

    // MARK: - Reload after a 409

    func testReloadReplacesTheProfileBehindTheSheet() async throws {
        let fresh = profile(version: 4, municipality: "Ловеч")
        let s = store(Wire { _ in fresh }, fetch: { fresh })
        s.setProfileForTesting(profile(version: 3), editable: true)
        let got = try await s.reloadProfile()
        XCTAssertEqual(got.version, 4)
        XCTAssertEqual(s.profile.value, fresh)
    }

    /// Edits survive the reload; fields the farmer left alone take what the
    /// other person stored; and the rebuilt body carries the NEW version.
    func testRebaseKeepsTheEditsAndTakesTheirOtherChanges() throws {
        let old = profile(version: 3)
        var draft = FarmProfileDraft(old)
        draft[.producerName] = "Иван Петров ЕТ"         // mine
        let fresh = profile(version: 4, municipality: "Ловеч") // theirs

        let r = FarmProfileRebase.rebase(draft, from: old, onto: fresh)
        XCTAssertEqual(r.draft[.producerName], "Иван Петров ЕТ")
        XCTAssertEqual(r.draft[.municipality], "Ловеч")
        XCTAssertEqual(r.collisions, [])

        let body = try FarmProfileUpdate.build(original: fresh, draft: r.draft).get()
        XCTAssertEqual(body.expectedVersion, 4)
        XCTAssertEqual(body.text[.municipality] ?? nil, "Ловеч",
                       "their change would be written back over with the stale value")
    }

    /// Both changed one field: mine stays in the box and theirs is SAID, so
    /// the next «Запази» is an informed overwrite, not a silent one.
    func testASameFieldCollisionIsNamedWithTheirValue() {
        let old = profile(version: 3)
        var draft = FarmProfileDraft(old)
        draft[.municipality] = "Русе"
        let r = FarmProfileRebase.rebase(draft, from: old,
                                         onto: profile(version: 4, municipality: "Ловеч"))
        XCTAssertEqual(r.draft[.municipality], "Русе")
        XCTAssertEqual(r.collisions, ["«Община»: друг потребител е записал «Ловеч»."])
    }

    func testTheSameEditOnBothSidesIsNotACollision() {
        let old = profile(version: 3)
        var draft = FarmProfileDraft(old)
        draft[.municipality] = "Ловеч"
        let r = FarmProfileRebase.rebase(draft, from: old,
                                         onto: profile(version: 4, municipality: "Ловеч"))
        XCTAssertEqual(r.collisions, [])
    }

    /// The ЕГН is never echoed, here as in the save report.
    func testAnEGNCollisionNeverCarriesTheNumber() {
        let old = profile(version: 3)
        var draft = FarmProfileDraft(old)
        draft[.egn] = "8001011111"
        let r = FarmProfileRebase.rebase(draft, from: old,
                                         onto: profile(version: 4, egn: "9001012222"))
        XCTAssertEqual(r.collisions.count, 1)
        XCTAssertFalse(r.collisions.joined().contains("9001012222"))
        XCTAssertFalse(r.collisions.joined().contains("8001011111"))
    }

    func testSizeAndCropCollisionsAreNamed() {
        let old = profile(version: 3)
        var draft = FarmProfileDraft(old)
        draft.sizeHa = "40"
        draft.crops = ["ечемик"]
        let r = FarmProfileRebase.rebase(draft, from: old,
                                         onto: profile(version: 4, sizeHa: 41, grain: ["царевица"]))
        XCTAssertEqual(r.draft.sizeHa, "40")
        XCTAssertEqual(r.draft.crops, ["ечемик"])
        XCTAssertEqual(r.collisions, ["Размер: друг потребител е записал 41 ха.",
                                      "Култури: друг потребител е записал царевица."])
    }
    // MARK: - The ЕИК through a reload (agri-saas#1352)

    private func withEIK(_ eik: String?, version: Int) -> FarmProfile {
        FarmProfile(producerName: "Иван Петров", eik: eik, egn: "7501011234",
                    address: nil, settlement: "Плевен", municipality: "Плевен",
                    registrationPlace: nil, registrationEkatte: "56722",
                    odbhCity: nil, agricultureDirectorateCity: nil,
                    urn: "1234567", sizeHa: 39.758, grainProduced: ["пшеница"],
                    version: version)
    }

    /// The 409 may BE staff verification writing the ЕИК. The reload takes
    /// the stored ЕИК, never carries a draft one across, names no collision
    /// for it — and the rebuilt body still has no `eik` key at all.
    func testTheReloadMergeNeverPutsTheEIKIntoTheBody() throws {
        let old = withEIK(nil, version: 3)
        var draft = FarmProfileDraft(old)
        draft[.municipality] = "Ловеч"
        draft[.eik] = "111111111"          // not offered by the editor; forced here
        let fresh = withEIK("203912345", version: 4)

        let r = FarmProfileRebase.rebase(draft, from: old, onto: fresh)
        XCTAssertEqual(r.draft[.eik], "203912345", "a draft ЕИК was carried over the stored one")
        XCTAssertEqual(r.draft[.municipality], "Ловеч")
        XCTAssertEqual(r.collisions, [])

        let body = try FarmProfileUpdate.build(original: fresh, draft: r.draft).get()
        XCTAssertEqual(body.expectedVersion, 4)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(json["eik"])
        XCTAssertEqual(json.count, 12)
        XCTAssertEqual(json["municipality"] as? String, "Ловеч", "positive control")
    }

    /// The ЕИК was not sent, so a different stored one after the save is not
    /// something the server "changed" from what the farmer typed.
    func testTheSaveReportSaysNothingAboutTheEIK() {
        let draft = FarmProfileDraft(withEIK(nil, version: 3))
        let notes = FarmProfileSaveReport.notes(draft: draft,
                                                saved: withEIK("203912345", version: 4))
        XCTAssertEqual(notes, [])
    }
}
