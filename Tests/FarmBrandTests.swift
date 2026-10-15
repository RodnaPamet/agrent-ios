import XCTest
@testable import Agrent

/// «Публичен профил» (agrent-ios #323): the draft's read, the save that
/// sends only what changed, the address's suggestions, and the field bounds.
/// Synthetic values throughout; nothing here reaches a network.
final class FarmBrandTests: XCTestCase {

    // MARK: - The draft

    /// A farm that never saved a draft is answered 200 `null` (agri-saas
    /// #1891), and the editor opens empty rather than failing.
    func testNoDraftIsNilNotAnError() throws {
        XCTAssertNil(try FarmBrandAPI.decodeDraft(from: Data("null".utf8)))
    }

    func testADraftReadsEveryField() throws {
        let body = #"""
        {"handle":"pobeda","displayName":"Тестово стопанство","tagline":"Кратко","about":"Дълго",
         "oblast":"Добрич","crops":["пшеница","слънчоглед"],"published":true,
         "publishedAt":"2026-10-15T08:00:00.000Z","consentedAt":"2026-10-15T07:59:00.000Z",
         "consentTextVersion":"v1","indexable":false}
        """#
        let draft = try XCTUnwrap(FarmBrandAPI.decodeDraft(from: Data(body.utf8)))
        XCTAssertEqual(draft.handle, "pobeda")
        XCTAssertEqual(draft.displayName, "Тестово стопанство")
        XCTAssertEqual(draft.oblast, "Добрич")
        XCTAssertEqual(draft.crops, ["пшеница", "слънчоглед"])
        XCTAssertTrue(draft.published)
        XCTAssertNotNil(draft.consentedAt)
    }

    /// One odd field costs that field. A body that isn't a draft at all
    /// fails: saving changed fields against a guessed draft would clear or
    /// keep the wrong ones.
    func testAnOddFieldCostsOnlyItself() throws {
        let draft = try XCTUnwrap(FarmBrandAPI.decodeDraft(
            from: Data(#"{"displayName":"Тестово","crops":"пшеница","published":"yes"}"#.utf8)))
        XCTAssertEqual(draft.displayName, "Тестово")
        XCTAssertEqual(draft.crops, [])
        XCTAssertFalse(draft.published)
        XCTAssertThrowsError(try FarmBrandAPI.decodeDraft(from: Data("[]".utf8)))
    }

    // MARK: - The save

    private func json(_ change: FarmBrandChange) throws -> [String: Any] {
        let data = try JSONEncoder().encode(change)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Untouched is left out; emptied is `null`, which is how the server
    /// clears; changed is the trimmed new text.
    func testOnlyWhatChangedIsSent() throws {
        let saved = FarmBrandDraft(displayName: "Тестово", tagline: "Старо", about: "Текст",
                                   oblast: "Русе", crops: ["пшеница"])
        var edited = saved
        edited.tagline = "  Ново  "
        edited.about = "   "
        let change = FarmBrandChange.between(saved, and: edited)
        let body = try json(change)
        XCTAssertEqual(body["tagline"] as? String, "Ново")
        XCTAssertTrue(body["about"] is NSNull, "an emptied field must clear, not be left out")
        XCTAssertNil(body["displayName"], "an untouched field must be left out")
        XCTAssertNil(body["oblast"])
        XCTAssertNil(body["crops"])
        XCTAssertEqual(Set(body.keys), ["tagline", "about"])
    }

    func testAnUnchangedDraftSendsNothing() {
        let saved = FarmBrandDraft(displayName: "Тестово", crops: ["пшеница"])
        XCTAssertTrue(FarmBrandChange.between(saved, and: saved).isEmpty)
        var spaced = saved
        spaced.displayName = "Тестово "
        spaced.crops = ["пшеница", " "]
        XCTAssertTrue(FarmBrandChange.between(saved, and: spaced).isEmpty, "whitespace is not a change")
    }

    /// The first save creates the draft, so every filled field goes; crops
    /// have no null, and an emptied list is sent as one.
    func testTheFirstSaveAndTheCrops() throws {
        let first = try json(FarmBrandChange.between(nil, and: FarmBrandDraft(displayName: "Тестово", crops: ["пшеница"])))
        XCTAssertEqual(first["displayName"] as? String, "Тестово")
        XCTAssertEqual(first["crops"] as? [String], ["пшеница"])
        XCTAssertNil(first["tagline"], "a field empty before and after is not a change")

        let cleared = try json(FarmBrandChange.between(FarmBrandDraft(crops: ["пшеница"]), and: FarmBrandDraft()))
        XCTAssertEqual(cleared["crops"] as? [String], [])
    }

    // MARK: - The address

    private func refusal(_ body: String, status: Int = 400) -> APIClient.APIError {
        let env = APIClient.envelope(from: Data(body.utf8))
        return .http(status: status, code: env?.code, message: env?.message, params: env?.params)
    }

    /// `details.suggestions` reaches the sheet. An empty list is a real
    /// answer and stays one; another refusal has none.
    func testATakenAddressCarriesItsSuggestions() {
        let taken = refusal(#"{"error":{"code":"FARM_HANDLE_TAKEN","message":"That address is already taken by another farm.","details":{"suggestions":["pobeda-dobrich","zp-pobeda"]}}}"#)
        XCTAssertEqual(FarmBrandAPI.suggestions(after: taken), ["pobeda-dobrich", "zp-pobeda"])

        let none = refusal(#"{"error":{"code":"FARM_HANDLE_TAKEN","message":"Taken.","details":{"suggestions":[]}}}"#)
        XCTAssertEqual(FarmBrandAPI.suggestions(after: none), [])

        let reserved = refusal(#"{"error":{"code":"FARM_HANDLE_RESERVED","message":"Reserved."}}"#)
        XCTAssertNil(FarmBrandAPI.suggestions(after: reserved))
        XCTAssertNil(FarmBrandAPI.suggestions(after: URLError(.notConnectedToInternet)))
    }

    /// The list rides in `params` without costing a value the route sent
    /// there itself, or the versions a 409 reads from `details`.
    func testSuggestionsLeaveTheRestOfTheEnvelopeAlone() {
        let env = APIClient.envelope(from: Data(#"{"error":{"code":"X","message":"m","params":{"max":40},"details":{"suggestions":["a-b"],"currentVersion":3}}}"#.utf8))
        XCTAssertEqual(env?.params?["max"], "40")
        XCTAssertEqual(env?.params?[APIClient.ErrorEnvelope.Err.suggestionsKey], "a-b")
        XCTAssertEqual(env?.details?.currentVersion, 3)
        let plain = APIClient.envelope(from: Data(#"{"error":{"code":"X","message":"m"}}"#.utf8))
        XCTAssertNil(plain?.params)
    }

    /// Every refusal the address can meet is said in Bulgarian.
    func testTheAddressRefusalsAreSaidInBulgarian() {
        for code in ["FARM_BRAND_NOT_FOUND", "FARM_HANDLE_TAKEN", "FARM_HANDLE_RESERVED",
                     "FARM_HANDLE_TOO_SHORT", "FARM_HANDLE_TOO_LONG", "FARM_HANDLE_UNUSABLE"] {
            let text = UserMessage.httpText(status: 400, code: code, message: "English.")
            XCTAssertNotEqual(text, UserMessage.statusText(400), code)
            XCTAssertTrue(UserMessage.isBulgarianSentence(text), "\(code): \(text)")
        }
    }

    /// What publishing and the A6 card need first, said in Bulgarian, and
    /// naming neither: the same two codes refuse both (agri-saas #1910).
    func testTheCardsRefusalsAreSaidInBulgarian() {
        for code in ["FARM_BRAND_HANDLE_REQUIRED", "FARM_BRAND_DISPLAY_NAME_REQUIRED", "FARM_BRAND_NOT_PUBLISHED"] {
            let text = UserMessage.httpText(status: 400, code: code, message: "Publish the farm profile first.")
            XCTAssertNotEqual(text, UserMessage.statusText(400), code)
            XCTAssertTrue(UserMessage.isBulgarianSentence(text), "\(code): \(text)")
        }
        XCTAssertFalse(UserMessage.httpText(status: 400, code: "FARM_BRAND_HANDLE_REQUIRED", message: nil).contains("карт"))
    }

    /// The card is a GET of the server's PDF, named after the farm as the
    /// server names it: in Cyrillic, which only `filename*` can carry, and
    /// the address when it names none.
    func testTheCardIsTheServersPDFNamedAfterTheFarm() throws {
        XCTAssertTrue(FarmBrandAPI.shareCardPath.hasSuffix("/farm-brand/share-card"), FarmBrandAPI.shareCardPath)
        XCTAssertTrue(FarmBrandAPI.shareCardPath.hasPrefix(FarmBrandAPI.draftPath))

        let name = "Синтетично стопанство.pdf"
        let encoded = try XCTUnwrap(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "."))))
        let header = "attachment; filename=\"sintetichno-stopanstvo.pdf\"; filename*=UTF-8''\(encoded)"
        let served = APIClient.fileName(contentDisposition: header)
        XCTAssertEqual(FarmRecordAPI.fileName(served, fallback: FarmBrandAPI.shareCardFallbackName("pobeda")), name)
        XCTAssertEqual(FarmRecordAPI.fileName(nil, fallback: FarmBrandAPI.shareCardFallbackName("pobeda")), "pobeda-karta.pdf")
        XCTAssertThrowsError(try FarmRecordAPI.keep(Data("{\"error\":{}}".utf8), named: "x.pdf"))
    }

    /// The page's address is the web share kit's (agri-saas #1885):
    /// the app's host, `/f/`, the handle.
    func testThePublicAddress() throws {
        let url = try XCTUnwrap(PublicProfileLink.url(handle: "pobeda"))
        XCTAssertEqual(url.path(), "/f/pobeda")
        XCTAssertEqual(url.host(), Config.baseURL.host())
        XCTAssertEqual(PublicProfileLink.displayAddress(handle: "pobeda"), "\(Config.baseURL.host() ?? "")/f/pobeda")
        XCTAssertTrue(PublicProfileView.claimedNote(HandleClaim(handle: "pobeda", normalised: true)).contains("/f/pobeda"))
    }

    // MARK: - The bounds

    func testTheServersBoundsAreCheckedFirst() {
        XCTAssertTrue(FarmBrandLimits.problems(in: FarmBrandDraft(displayName: "Тестово")).isEmpty)
        let long = FarmBrandDraft(displayName: String(repeating: "а", count: 121),
                                  tagline: String(repeating: "б", count: 201),
                                  crops: Array(repeating: "пшеница", count: 41) + [String(repeating: "в", count: 81)])
        let problems = FarmBrandLimits.problems(in: long)
        XCTAssertEqual(problems.count, 4, "\(problems)")
        XCTAssertTrue(problems.allSatisfy(UserMessage.isBulgarianSentence), "\(problems)")
    }

    /// The server's names, in Bulgarian order, and a saved value from
    /// elsewhere kept so opening the editor doesn't change it.
    func testTheOblastsAreTheServersNames() {
        let names = FarmBrandLimits.oblasts(keeping: nil)
        XCTAssertEqual(names.count, 28)
        XCTAssertTrue(names.contains("Добрич"))
        XCTAssertEqual(names.first, "Благоевград")
        XCTAssertEqual(FarmBrandLimits.oblasts(keeping: "Добрич"), names)
        XCTAssertEqual(FarmBrandLimits.oblasts(keeping: "област Добрич").first, "област Добрич")
    }

    // MARK: - Where it's offered

    /// Only behind the flag the server gates every P6 route on, and only on
    /// Админ's admin branch.
    func testTheEditorIsBehindTheFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let admin = try String(contentsOf: root.appendingPathComponent("Agrent/Admin/AdminView.swift"), encoding: .utf8)
        XCTAssertTrue(admin.contains("struct AdminView"), "positive control")
        XCTAssertTrue(admin.contains("if flags.isOn(FarmBrandAPI.flag) {"))
        XCTAssertEqual(FarmBrandAPI.flag, "social.public-profile")
        let allowed = try XCTUnwrap(admin.range(of: "case .allowed:"))
        let row = try XCTUnwrap(admin.range(of: "Section { publicProfileRow }"))
        XCTAssertLessThan(allowed.lowerBound, row.lowerBound, "offered outside the admin branch")
    }
}
