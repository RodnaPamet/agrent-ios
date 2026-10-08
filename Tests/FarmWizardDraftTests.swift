import XCTest
@testable import Agrent

/// The farm wizard resumes where the person left it if the app is killed
/// (agrent-ios#197, P4.8). NOTHING HERE CREATES A FARM: the check and the
/// send are injected, and the drafts live in a throwaway `UserDefaults`
/// suite. Each "next launch" is a new model over the same storage.
@MainActor
final class FarmWizardDraftTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard

    override func setUp() async throws {
        try await super.setUp()
        suite = "test.wizard.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private var drafts: FarmWizardDrafts { FarmWizardDrafts(defaults: defaults) }

    private func wizard(
        owner: String? = "usr_1",
        verdict: FarmsAPI.EikVerdict = .init(valid: true, looksLikeEgn: false, registryName: "Синтетично ЕООД"),
        checked: ((String) -> Void)? = nil
    ) -> FarmWizardModel {
        FarmWizardModel(
            check: { eik in
                checked?(eik)
                return verdict
            },
            send: { request in
                .init(farm: .init(id: "ten_1", slug: "sintetichno-x1", name: request.name),
                      identityVerification: .pendingReview)
            },
            debounce: .zero, drafts: drafts, owner: owner)
    }

    /// Waits out the debounced check.
    private func settle(_ model: FarmWizardModel) async throws {
        for _ in 0..<100 where model.eikState == .checking {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testAnIndividualResumesAtTheNameWithItTyped() {
        let first = wizard()
        first.choose(.individual)
        first.name = "Синтетично стопанство"

        let next = wizard()
        XCTAssertEqual(next.step, .name)
        XCTAssertEqual(next.kind, .individual)
        XCTAssertEqual(next.name, "Синтетично стопанство")
        XCTAssertEqual(next.position.current, 2, "the counter resumes on the person's own walk")

        // A resume writes the draft back WHOLE: killed again straight after
        // it, the person still comes back to the name, not to the start.
        let again = wizard()
        XCTAssertEqual(again.step, .name)
        XCTAssertEqual(again.name, "Синтетично стопанство")
    }

    /// A kept ЕИК is asked of the register AGAIN on resume; until it answers
    /// it stays the verified one, so a kill during that check loses nothing.
    func testACompanyResumesWithItsVerifiedEikAskedAgain() async throws {
        let first = wizard()
        first.choose(.company)
        first.setEik("123456789")
        try await settle(first)
        first.confirmEik()
        XCTAssertEqual(first.step, .name)

        var asked: [String] = []
        let next = wizard(checked: { asked.append($0) })
        XCTAssertEqual(next.step, .name)
        XCTAssertEqual(next.eik, "123456789")
        XCTAssertEqual(drafts.draft(for: "usr_1")?.eik, "123456789",
                       "the check under way after a resume dropped the kept ЕИК")
        try await settle(next)
        XCTAssertEqual(asked, ["123456789"])
        XCTAssertEqual(next.request.eik, "123456789")
        XCTAssertEqual(next.name, "Синтетично ЕООД", "the register's name came back with it")
    }

    /// The rule the draft exists under: an ЕГН never reaches the phone's
    /// storage — and neither does a half-typed or a refused ЕИК.
    func testOnlyAVerifiedEikIsKept() async throws {
        let egn = wizard(verdict: .init(valid: false, looksLikeEgn: true, registryName: nil))
        egn.choose(.company)
        egn.setEik("8001010000")
        try await settle(egn)
        XCTAssertEqual(egn.eikState, .looksLikeEgn)
        XCTAssertEqual(drafts.draft(for: "usr_1")?.eik, "", "an ЕГН reached the phone's storage")

        let refused = wizard(verdict: .init(valid: false, looksLikeEgn: false, registryName: nil))
        refused.choose(.company)
        refused.setEik("123456789")
        try await settle(refused)
        XCTAssertEqual(drafts.draft(for: "usr_1")?.eik, "")

        let typing = wizard()
        typing.choose(.company)
        typing.setEik("1234")
        XCTAssertEqual(drafts.draft(for: "usr_1")?.eik, "")

        // Positive control: a VALID one is kept, so the empties above are real.
        typing.setEik("123456789")
        try await settle(typing)
        XCTAssertEqual(drafts.draft(for: "usr_1")?.eik, "123456789")
        // And editing it away from the verified one unkeeps it.
        typing.setEik("12345678")
        XCTAssertEqual(drafts.draft(for: "usr_1")?.eik, "")
    }

    func testAnotherPersonDoesNotResumeIt() {
        let first = wizard(owner: "usr_1")
        first.choose(.individual)
        first.name = "Синтетично"

        let other = wizard(owner: "usr_2")
        XCTAssertEqual(other.step, .type)
        XCTAssertEqual(other.name, "")
    }

    func testCreatingTheFarmLeavesNothingToResume() async {
        let first = wizard()
        first.choose(.individual)
        first.name = "Синтетично"
        await first.submit()
        XCTAssertEqual(first.step, .done)
        XCTAssertNil(drafts.draft(for: "usr_1"))
        XCTAssertNil(defaults.data(forKey: FarmWizardDrafts.key))
    }

    func testCancellingLeavesNothingToResume() {
        let first = wizard()
        first.choose(.individual)
        first.name = "Синтетично"
        XCTAssertNotNil(drafts.draft(for: "usr_1"), "positive control: there was one")
        first.discard()
        XCTAssertNil(drafts.draft(for: "usr_1"))
    }

    /// The default — no storage, no owner — keeps nothing: every other test
    /// of the wizard runs without touching the phone's storage.
    func testWithoutAnOwnerNothingIsKept() {
        let first = wizard(owner: nil)
        first.choose(.individual)
        first.name = "Синтетично"
        XCTAssertNil(defaults.data(forKey: FarmWizardDrafts.key))
    }

    /// A half-made farm's name does not stay on a shared phone after Изход.
    func testSignOutClearsIt() {
        let real = FarmWizardDrafts(defaults: .standard)
        real.save(FarmWizardDraft(owner: "usr_1", step: .name, kind: .individual,
                                  eik: "", name: "Синтетично", prefilled: nil))
        XCTAssertNotNil(UserDefaults.standard.data(forKey: FarmWizardDrafts.key), "positive control")
        SessionReset.resetUserState()
        XCTAssertNil(UserDefaults.standard.data(forKey: FarmWizardDrafts.key))
    }
}
