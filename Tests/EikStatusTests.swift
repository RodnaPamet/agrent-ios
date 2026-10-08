import XCTest
@testable import Agrent

/// The ЕИК verification status — agri-saas#1355, `FarmProfile.eikVerification`.
///
/// Three things are held here: the four wire values decode and anything else
/// degrades to a case that shows nothing; the copy each state shows; and the
/// DISPUTED line, which the spec says in bold must not read as an accusation.
@MainActor
final class EikStatusTests: XCTestCase {

    // MARK: - Decoding

    private let fields = """
    "producerName":null,"egn":null,"eik":"000000000","urn":null,"address":null,
    "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
    "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
    "sizeHa":null,"grainProduced":[],"version":3
    """

    private func decode(_ tail: String) async throws -> FarmProfile {
        try await AdminAPI.decodeFarmProfile(from: Data("{\(fields)\(tail)}".utf8))
    }

    func testTheFourDocumentedValuesDecode() async throws {
        let expected: [(String, EikVerification)] = [
            ("NONE", .unclaimed), ("PENDING", .pending),
            ("VERIFIED", .verified), ("DISPUTED", .disputed),
        ]
        for (wire, state) in expected {
            let p = try await decode(#","eikVerification":"\#(wire)""#)
            XCTAssertEqual(p.eikVerification, state, wire)
            XCTAssertEqual(p.eikState, state, wire)
        }
    }

    /// The enum's raw values ARE the spec's four, and nothing else is a wire
    /// value but the lenient fallback.
    func testTheRawValuesAreTheSpecsEnum() {
        XCTAssertEqual(Set(EikVerification.allCases.map(\.rawValue)),
                       ["NONE", "PENDING", "VERIFIED", "DISPUTED", "UNKNOWN"])
    }

    /// A value a later server adds costs the status line, never the screen.
    func testAnUnknownValueDecodesAsUnknownAndTheProfileStillLoads() async throws {
        let p = try await decode(#","eikVerification":"REVOKED""#)
        XCTAssertEqual(p.eikState, .unknown)
        XCTAssertEqual(p.eik, "000000000")
    }

    /// A server from before #1355 omits the key; the spec never says null,
    /// but null is folded the same way rather than trusted not to happen.
    func testAnAbsentOrNullValueIsUnknown() async throws {
        let absent = try await decode("")
        XCTAssertNil(absent.eikVerification)
        XCTAssertEqual(absent.eikState, .unknown)

        let null = try await decode(#","eikVerification":null"#)
        XCTAssertEqual(null.eikState, .unknown)
    }

    /// The A11yShots fixture carries DISPUTED, through the app's own decode.
    func testTheSyntheticFixtureCarriesAStatus() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "admin-farm-profile", withExtension: "json"))
        let p = try await AdminAPI.decodeFarmProfile(from: Data(contentsOf: url))
        XCTAssertEqual(p.eikState, .disputed)
    }

    // MARK: - Copy

    func testTheCopyForEveryState() {
        XCTAssertEqual(EikStatus.text(for: .unclaimed), "Непроверен")
        XCTAssertEqual(EikStatus.text(for: .pending), "В процес на проверка")
        XCTAssertEqual(EikStatus.text(for: .verified), "Проверен")
        XCTAssertEqual(EikStatus.text(for: .disputed),
                       "Не съвпада със съществуващ запис — свържете се с екипа на Agrent.")
        XCTAssertNil(EikStatus.text(for: .unknown))
    }

    /// Colour roles: success for VERIFIED, neutral for NONE and PENDING,
    /// warning — never error — for DISPUTED. And the tick is VERIFIED's alone.
    func testToneAndSymbolPerState() {
        XCTAssertEqual(EikStatus.of(.verified, hasNumber: true)?.tone, .success)
        XCTAssertEqual(EikStatus.of(.verified, hasNumber: true)?.symbol, "checkmark.seal.fill")
        XCTAssertEqual(EikStatus.of(.unclaimed, hasNumber: true)?.tone, .neutral)
        XCTAssertNil(EikStatus.of(.unclaimed, hasNumber: true)?.symbol)
        XCTAssertEqual(EikStatus.of(.pending, hasNumber: false)?.tone, .neutral)
        XCTAssertEqual(EikStatus.of(.disputed, hasNumber: false)?.tone, .warning)
        for state in EikVerification.allCases where state != .verified {
            XCTAssertNotEqual(EikStatus.of(state, hasNumber: true)?.symbol?.contains("checkmark"), true,
                              "\(state) must not wear the verified tick")
        }
    }

    /// Unknown shows nothing; NONE shows nothing without a number; PENDING
    /// and DISPUTED show WITHOUT one, because the server writes `eik` only
    /// at verification and a farm under review has none yet.
    func testWhenNothingIsShown() {
        XCTAssertNil(EikStatus.of(.unknown, hasNumber: true))
        XCTAssertNil(EikStatus.of(.unknown, hasNumber: false))
        XCTAssertNil(EikStatus.of(.unclaimed, hasNumber: false))
        XCTAssertNotNil(EikStatus.of(.pending, hasNumber: false))
        XCTAssertNotNil(EikStatus.of(.disputed, hasNumber: false))

        XCTAssertFalse(EikStatus.showsRow(eik: nil, state: .unclaimed))
        XCTAssertFalse(EikStatus.showsRow(eik: "  ", state: .unknown))
        XCTAssertTrue(EikStatus.showsRow(eik: nil, state: .pending))
        XCTAssertTrue(EikStatus.showsRow(eik: "000000000", state: .unknown))
    }

    // MARK: - DISPUTED is not an accusation

    /// Word STEMS, so every inflection is caught: «оспорен», «оспорено»,
    /// «невалиден», «невалидна»… Each one either says the farmer did
    /// something wrong or that the number is wrong, and the spec allows
    /// neither: the state means only that the claim met an existing verified
    /// claim, which a mistyped digit causes as readily as anything.
    static let accusatory = [
        "оспор", "невалид", "грешн", "погрешн", "фалшив", "измам", "подправ",
        "неверн", "незакон", "нарушен", "злоупотреб", "отхвърл", "отказ",
        "блокир", "чужд", "присвоен", "подозр",
    ]

    func testTheDisputedLineAccusesNobody() throws {
        let line = try XCTUnwrap(EikStatus.text(for: .disputed)).lowercased()
        for stem in Self.accusatory {
            XCTAssertFalse(line.contains(stem), "«\(line)» contains «\(stem)»")
        }
        // Actionable: it names who to contact.
        XCTAssertTrue(line.contains("свържете се"))
        XCTAssertTrue(line.contains("agrent"))
    }

    /// Positive control: the check fires on a line that DOES accuse, so the
    /// green above is a finding and not a list that matches nothing.
    func testTheAccusationCheckCanFail() {
        let bad = "ЕИК е оспорен — номерът е невалиден.".lowercased()
        XCTAssertTrue(Self.accusatory.contains { bad.contains($0) })
    }

    // MARK: - Speech

    /// One sentence: label, the digits one by one, the status.
    func testTheRowIsSpokenAsOneSentence() {
        XCTAssertEqual(EikStatus.spoken(eik: "203912345", state: .verified),
                       "ЕИК 2 0 3 9 1 2 3 4 5, Проверен.")
        XCTAssertEqual(EikStatus.spoken(eik: "203912345", state: .unclaimed),
                       "ЕИК 2 0 3 9 1 2 3 4 5, Непроверен.")
        XCTAssertEqual(EikStatus.spoken(eik: nil, state: .pending),
                       "ЕИК, не е попълнено, В процес на проверка.")
        // Ends in its own full stop; not doubled.
        XCTAssertEqual(EikStatus.spoken(eik: nil, state: .disputed),
                       "ЕИК, не е попълнено, Не съвпада със съществуващ запис — "
                       + "свържете се с екипа на Agrent.")
        // Unknown says the number and nothing about it.
        XCTAssertEqual(EikStatus.spoken(eik: "203912345", state: .unknown),
                       "ЕИК 2 0 3 9 1 2 3 4 5.")
    }

    // MARK: - The save reports it

    /// Since agri-saas #1375 the PUT derives the status as the GET does, so
    /// the store shows the PUT's — the freshest there is. A verification that
    /// landed while the page was open shows on the save, not one GET later.
    func testASaveShowsTheStatusThePutReports() async throws {
        func profile(_ state: EikVerification?, municipality: String? = nil) -> FarmProfile {
            FarmProfile(producerName: nil, eik: "000000000", egn: nil, address: nil,
                        settlement: nil, municipality: municipality,
                        registrationPlace: nil, registrationEkatte: nil,
                        odbhCity: nil, agricultureDirectorateCity: nil,
                        urn: nil, sizeHa: nil, grainProduced: [],
                        version: 3, eikVerification: state)
        }
        let store = AdminStore(
            sendProfile: { body in profile(.verified, municipality: body.text[.municipality] ?? nil) },
            fetchProfile: { throw URLError(.notConnectedToInternet) })
        store.setProfileForTesting(profile(.pending), editable: true)

        let original = try XCTUnwrap(store.profile.value)
        var draft = FarmProfileDraft(original)
        draft[.municipality] = "Ловеч"
        guard case .success(let body) = FarmProfileUpdate.build(original: original, draft: draft) else {
            return XCTFail("the body did not build")
        }
        try await store.saveProfile(body, typed: draft)

        XCTAssertEqual(store.profile.value?.municipality, "Ловеч", "the response did replace the profile")
        XCTAssertEqual(store.profile.value?.eikState, .verified,
                       "the status held before the save was kept over the PUT's")
    }
}
