import XCTest
@testable import Agrent

/// Creating a farm (agrent-ios#179). NOTHING HERE CREATES ONE: the model's
/// check and send are injected closures, and the real `FarmsAPI.create` is
/// never called — a farm made from a test would be a real farm.
@MainActor
final class FarmWizardModelTests: XCTestCase {

    private struct Refused: Error {}

    private func model(
        verdict: FarmsAPI.EikVerdict? = .init(valid: true, looksLikeEgn: false, registryName: "Синтетично ЕООД"),
        created: FarmsAPI.Created? = nil, failure: Error? = nil,
        checked: ((String) -> Void)? = nil, sent: ((FarmsAPI.CreateFarm) -> Void)? = nil
    ) -> FarmWizardModel {
        FarmWizardModel(
            check: { eik in
                checked?(eik)
                guard let verdict else { throw Refused() }
                return verdict
            },
            send: { request in
                sent?(request)
                if let failure { throw failure }
                return created ?? .init(farm: .init(id: "ten_1", slug: "sintetichno-eood-x7", name: request.name),
                                        identityVerification: .pendingReview)
            },
            debounce: .zero)
    }

    /// Waits out the debounced check.
    private func settle(_ model: FarmWizardModel) async throws {
        for _ in 0..<100 where model.eikState == .checking {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The walk

    func testTheWalkIsThisPersonsWalk() {
        let company = model()
        company.choose(.company)
        XCTAssertEqual(company.step, .eik)
        XCTAssertEqual(company.walk, [.type, .eik, .name, .done])
        XCTAssertTrue(company.position == (2, 4))

        let individual = model()
        individual.choose(.individual)
        XCTAssertEqual(individual.step, .name, "the физическо лице path asked for an ЕИК")
        XCTAssertTrue(individual.position == (2, 3), "the counter promised a step this person never walks")
    }

    func testBackWalksThePathAndNotPastTheFarm() async {
        let individual = model()
        individual.choose(.individual)
        individual.back()
        XCTAssertEqual(individual.step, .type)

        let done = model()
        done.choose(.individual)
        done.name = "Синтетично стопанство"
        await done.submit()
        XCTAssertEqual(done.step, .done, "positive control: the farm was made")
        done.back()
        XCTAssertEqual(done.step, .done, "back from done would offer to create the farm again")
    }

    // MARK: - The ЕИК

    /// Nothing is asked under nine characters; a ten-digit ЕГН IS asked
    /// about, which is how it is caught.
    func testTheRegisterIsAskedFromNineCharacters() async throws {
        var asked: [String] = []
        let wizard = model(checked: { asked.append($0) })
        wizard.choose(.company)
        wizard.setEik("12345678")
        XCTAssertEqual(wizard.eikState, .idle)
        wizard.setEik(" 1234567890 ")
        try await settle(wizard)
        XCTAssertEqual(asked, ["1234567890"], "sent untrimmed, or not sent at ten digits")
    }

    /// An ЕГН typed by mistake stops the step dead.
    func testAnEgnStopsTheStep() async throws {
        let wizard = model(verdict: .init(valid: false, looksLikeEgn: true, registryName: nil))
        wizard.choose(.company)
        wizard.setEik("8001010000")
        try await settle(wizard)
        XCTAssertEqual(wizard.eikState, .looksLikeEgn)
        XCTAssertFalse(wizard.mayConfirmEik)
        wizard.confirmEik()
        XCTAssertEqual(wizard.step, .eik, "an ЕГН went on to the name step")
    }

    func testAnInvalidEikDoesNotGoOn() async throws {
        let wizard = model(verdict: .init(valid: false, looksLikeEgn: false, registryName: nil))
        wizard.choose(.company)
        wizard.setEik("123456789")
        try await settle(wizard)
        XCTAssertEqual(wizard.eikState, .invalid)
        wizard.confirmEik()
        XCTAssertEqual(wizard.step, .eik)
    }

    func testACheckThatCannotBeMadeSaysSo() async throws {
        let wizard = model(verdict: nil)
        wizard.choose(.company)
        wizard.setEik("123456789")
        try await settle(wizard)
        guard case .failed(let message) = wizard.eikState else {
            return XCTFail("a failed check read as \(wizard.eikState)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(wizard.mayConfirmEik)
    }

    /// The register's name fills the name step — and never replaces a name
    /// the farmer typed themselves.
    func testTheRegistersNamePrefillsButNeverOverwrites() async throws {
        let wizard = model()
        wizard.choose(.company)
        wizard.setEik("123456789")
        try await settle(wizard)
        XCTAssertEqual(wizard.eikState, .valid(registryName: "Синтетично ЕООД"))
        wizard.confirmEik()
        XCTAssertEqual(wizard.step, .name)
        XCTAssertEqual(wizard.name, "Синтетично ЕООД")

        wizard.back()
        wizard.name = "Моето стопанство"
        wizard.confirmEik()
        XCTAssertEqual(wizard.name, "Моето стопанство", "the farmer's own name was overwritten")
    }

    // MARK: - The request

    /// «Земеделски стопанин» sends no ЕИК at all — absent, not null — even
    /// if one was typed before switching kind.
    func testTheIndividualPathOmitsTheEik() throws {
        let wizard = model()
        wizard.choose(.company)
        wizard.setEik("123456789")
        wizard.back()
        wizard.choose(.individual)
        wizard.name = "  Синтетично стопанство  "
        XCTAssertEqual(wizard.request, .init(name: "Синтетично стопанство", eik: nil))
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(wizard.request), encoding: .utf8))
        XCTAssertFalse(json.contains("eik"), "eik went out as null: \(json)")

        let company = model()
        company.choose(.company)
        company.setEik(" 123456789 ")
        company.name = "Синтетично ЕООД"
        XCTAssertEqual(company.request, .init(name: "Синтетично ЕООД", eik: "123456789"))
    }

    // MARK: - Creating

    func testACreatedFarmOpensByTheSlugItCameBackWith() async {
        let wizard = model()
        wizard.choose(.individual)
        wizard.name = "Синтетично стопанство"
        await wizard.submit()
        XCTAssertEqual(wizard.step, .done)
        // Its creator is its OWNER (the spec, on the POST): it opens on that
        // role, not on the oldest membership's.
        XCTAssertEqual(wizard.farm, Farm(slug: "sintetichno-eood-x7", name: "Синтетично стопанство",
                                         role: "OWNER"))
        XCTAssertEqual(wizard.created?.identityVerification, .pendingReview)
    }

    func testABlankNameIsNotSent() async {
        var sends = 0
        let wizard = model(sent: { _ in sends += 1 })
        wizard.choose(.individual)
        wizard.name = "   "
        XCTAssertFalse(wizard.maySubmit)
        await wizard.submit()
        XCTAssertEqual(sends, 0)
    }

    /// A refusal is said in Bulgarian, by its code, on the step it came from.
    func testARefusalIsSaidByItsCode() async {
        let wizard = model(failure: APIClient.APIError.http(
            status: 400, code: "FARM_NAME_NOT_SLUGGABLE", message: nil, params: nil, retryAfterSeconds: nil))
        wizard.choose(.individual)
        wizard.name = "!!!"
        await wizard.submit()
        XCTAssertEqual(wizard.step, .name)
        XCTAssertEqual(wizard.error, UserMessage.httpText(status: 400, code: "FARM_NAME_NOT_SLUGGABLE", message: nil))
        XCTAssertFalse(wizard.needsTerms)
    }

    /// The terms gate is a refusal the farmer can act on, so it is marked.
    func testTheTermsGateIsMarked() async {
        let wizard = model(failure: APIClient.APIError.http(
            status: 403, code: "TERMS_ACCEPTANCE_REQUIRED", message: nil, params: nil, retryAfterSeconds: nil))
        wizard.choose(.individual)
        wizard.name = "Синтетично стопанство"
        await wizard.submit()
        XCTAssertTrue(wizard.needsTerms)
        XCTAssertEqual(wizard.step, .name)
    }
}

/// The two refusals whose code is not where the spec puts codes.
final class FarmErrorShapeTests: XCTestCase {

    private func envelope(_ json: String) -> APIClient.ErrorEnvelope.Err? {
        APIClient.envelope(from: Data(json.utf8))
    }

    /// #1362 ships its codes in `message`, under `BAD_REQUEST`.
    func testAFarmCodeInTheMessageIsReadAsTheCode() {
        let err = envelope(#"{"error":{"code":"BAD_REQUEST","message":"EIK_LOOKS_LIKE_EGN","requestId":"r"}}"#)
        XCTAssertEqual(err?.code, "EIK_LOOKS_LIKE_EGN")
    }

    /// Whitelisted: any other message under `BAD_REQUEST` stays prose.
    func testOtherProseStaysProse() {
        let err = envelope(#"{"error":{"code":"BAD_REQUEST","message":"Something else entirely"}}"#)
        XCTAssertEqual(err?.code, "BAD_REQUEST")
        XCTAssertEqual(err?.message, "Something else entirely")
        // And a real code is never touched.
        XCTAssertEqual(envelope(#"{"error":{"code":"FORBIDDEN","message":"FARM_NAME_REQUIRED"}}"#)?.code,
                       "FORBIDDEN")
    }

    /// The terms gate's bare-string 403.
    func testTheTermsGateIsCoded() {
        XCTAssertEqual(envelope(#"{"error":"Terms acceptance required"}"#)?.code, "TERMS_ACCEPTANCE_REQUIRED")
        // Positive control: the bare-string shape still reads as before.
        XCTAssertEqual(envelope(#"{"error":"invalid_grant"}"#)?.code, "invalid_grant")
    }

    /// Every one of them reads in Bulgarian, as a sentence.
    func testEveryFarmRefusalHasBulgarianWords() {
        for code in APIClient.farmCreationCodes.sorted() + ["TERMS_ACCEPTANCE_REQUIRED"] {
            let text = UserMessage.httpText(status: 400, code: code, message: nil)
            XCTAssertNotEqual(text, UserMessage.statusText(400), "\(code) has no words of its own")
            XCTAssertTrue(text.hasSuffix("."), "not a sentence: \(text)")
            XCTAssertNil(text.range(of: "[A-Za-z]", options: .regularExpression), "Latin in \(code): \(text)")
        }
    }

    func testTheIdentityResultReadsLenientlyAndNeverAsAcceptance() throws {
        let decode = { (raw: String) in
            try JSONDecoder().decode(FarmsAPI.IdentityVerification.self, from: Data("\"\(raw)\"".utf8))
        }
        XCTAssertEqual(try decode("pending_review"), .pendingReview)
        XCTAssertEqual(try decode("not_requested"), .notRequested)
        XCTAssertEqual(try decode("something_new"), .unknown)
        XCTAssertEqual(FarmWizardText.identityLine(.pendingReview), FarmWizardText.doneIdentityPending)
        XCTAssertEqual(FarmWizardText.identityLine(.unknown), FarmWizardText.doneIdentityNone)
    }
}
