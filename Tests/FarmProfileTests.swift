import XCTest
@testable import Agrent

/// The holding fields — agri-saas#1141, documented by #1145.
///
/// Three properties that are easy to get wrong by pattern-matching the ten
/// producer fields above them, and one of them fails in the direction that
/// looks like an empty database rather than a bug.
@MainActor
final class FarmProfileHoldingTests: XCTestCase {

    private func profile(_ json: String) async throws -> FarmProfile {
        try await AdminAPI.decodeFarmProfile(from: Data(json.utf8))
    }

    private let full = """
    {"producerName":"Иван Петров","egn":"7501011234","eik":"203912345",
     "urn":"1234567","address":"ул. Дунав 3","municipality":"Плевен",
     "settlement":"Плевен","agricultureDirectorateCity":"Плевен",
     "registrationPlace":"Плевен","registrationEkatte":"56722",
     "odbhCity":"Плевен","sizeHa":124.5,"grainProduced":["wheat","barley"]}
    """

    func testTheDocumentedShapeDecodes() async throws {
        let p = try await profile(full)
        XCTAssertEqual(p.urn, "1234567")
        XCTAssertEqual(p.sizeHa, 124.5)
        XCTAssertEqual(p.grainProduced, ["wheat", "barley"])
        XCTAssertFalse(p.isEmpty)
    }

    /// `grainProduced` IS NOT OPTIONAL, which breaks the shape of every field
    /// beside it. It is in `required` and is `type: array` with no null, so
    /// `[]` is the empty case and there is no third state. An optional here
    /// would model something the server cannot produce.
    func testAnEmptyCropListIsAnArrayRatherThanNil() async throws {
        let p = try await profile("""
        {"producerName":null,"egn":null,"eik":null,"urn":null,"address":null,
         "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
         "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
         "sizeHa":null,"grainProduced":[]}
        """)
        XCTAssertEqual(p.grainProduced, [])
        XCTAssertTrue(p.isEmpty)
    }

    /// THE ONE THAT FAILS QUIETLY. A tenant who fills only the three new
    /// fields — the three that just arrived, so the plausible near-term state
    /// — must not be reported as "nothing filled in" over three populated
    /// rows. That error looks like an empty database rather than a bug.
    func testAProfileCarryingOnlyTheHoldingFieldsIsNotEmpty() async throws {
        let onlyUrn = try await profile("""
        {"producerName":null,"egn":null,"eik":null,"urn":"1234567","address":null,
         "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
         "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
         "sizeHa":null,"grainProduced":[]}
        """)
        XCTAssertFalse(onlyUrn.isEmpty, "a declared УРН read as nothing filled in")

        let onlySize = try await profile("""
        {"producerName":null,"egn":null,"eik":null,"urn":null,"address":null,
         "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
         "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
         "sizeHa":124.5,"grainProduced":[]}
        """)
        XCTAssertFalse(onlySize.isEmpty, "a declared size read as nothing filled in")

        let onlyCrops = try await profile("""
        {"producerName":null,"egn":null,"eik":null,"urn":null,"address":null,
         "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
         "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
         "sizeHa":null,"grainProduced":["wheat"]}
        """)
        XCTAssertFalse(onlyCrops.isEmpty, "declared crops read as nothing filled in")
    }

    /// NULL AND ZERO ARE DIFFERENT CLAIMS. Null is "not declared"; 0 is a
    /// declaration of zero hectares, which is something the farm told the
    /// state. A profile declaring zero is not an empty profile.
    func testADeclaredZeroIsADeclarationRatherThanAnAbsence() async throws {
        let zero = try await profile("""
        {"producerName":null,"egn":null,"eik":null,"urn":null,"address":null,
         "municipality":null,"settlement":null,"agricultureDirectorateCity":null,
         "registrationPlace":null,"registrationEkatte":null,"odbhCity":null,
         "sizeHa":0,"grainProduced":[]}
        """)
        XCTAssertEqual(zero.sizeHa, 0)
        XCTAssertFalse(zero.isEmpty, "a declared zero was collapsed into «not filled in»")
    }

    /// `sizeHa` is a NUMBER. The habit in this repo is that server decimals
    /// arrive as strings — `quantityTonnes`, `WireDecimal` — and that habit
    /// came from MONEY, where a float cannot hold a cent. Hectares to three
    /// decimals are exactly representable and the contract says `number`.
    func testTheSizeIsANumberOnTheWireAndNotADecimalString() async throws {
        let p = try await profile(full.replacingOccurrences(
            of: "\"sizeHa\":124.5", with: "\"sizeHa\":124.125"))
        XCTAssertEqual(try XCTUnwrap(p.sizeHa), 124.125, accuracy: 0.0000001)
        // A string would have to be refused rather than coerced, so that the
        // failure is visible if the contract ever changes under us.
        await XCTAssertThrowsErrorAsync(try await profile(full.replacingOccurrences(
            of: "\"sizeHa\":124.5", with: "\"sizeHa\":\"124.5\"")))
    }
}

/// `XCTAssertThrowsError` has no async form.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
