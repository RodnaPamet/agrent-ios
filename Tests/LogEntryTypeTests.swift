import XCTest
@testable import Agrent

/// `LogEntryType` shipped SIX cases against the server's TEN and invented an
/// `OTHER` the server has never had. It never bit only because the live tenant
/// happens to hold nothing but INPUT_APPLICATION and ACTIVITY — the first
/// Сеитба entry would have failed the WHOLE list decode, every row vanishing
/// rather than the one.
///
/// The fix was verified by READING `enums.prisma`. This verifies the client
/// half by executing it, which is the half a scratch tenant could not have
/// proved better: writing five junk entries into a live multi-tenant database
/// would demonstrate less than this does.
final class LogEntryTypeTests: XCTestCase {

    /// Exactly the ten values in the server's enum. Written out literally
    /// rather than derived from `allCases`, so that this fails if a case is
    /// added, removed or renamed — a test generated from the thing it checks
    /// cannot detect a change to it.
    private let serverRawValues = [
        "ACTIVITY", "OBSERVATION", "INPUT_APPLICATION", "SEEDING",
        "TRANSPLANTING", "HARVEST", "IRRIGATION", "MAINTENANCE",
        "LAB_TEST", "GRAZING",
    ]

    func testEveryServerValueDecodes() throws {
        for raw in serverRawValues {
            let json = Data("\"\(raw)\"".utf8)
            let decoded = try JSONDecoder().decode(LogEntryType.self, from: json)
            XCTAssertEqual(decoded.rawValue, raw, "\(raw) decoded to \(decoded.rawValue)")
        }
    }

    func testCaseCountMatchesServer() {
        XCTAssertEqual(
            Set(LogEntryType.allCases.map(\.rawValue)),
            Set(serverRawValues),
            "app enum and server enum have diverged"
        )
    }

    /// `OTHER` was invented client-side and the server would have rejected a
    /// create using it.
    func testInventedCaseIsGone() {
        XCTAssertFalse(LogEntryType.allCases.map(\.rawValue).contains("OTHER"))
    }

    func testEveryCaseHasADistinctBulgarianLabel() {
        let labels = LogEntryType.allCases.map(\.label)
        for (type, label) in zip(LogEntryType.allCases, labels) {
            XCTAssertFalse(label.isEmpty, "\(type.rawValue) has no label")
            XCTAssertNotEqual(label, type.rawValue, "\(type.rawValue) label is untranslated")
        }
        XCTAssertEqual(Set(labels).count, labels.count, "two cases share a label")
    }

    /// Documents current behaviour rather than endorsing it: an unrecognised
    /// type throws, and because `LogEntry.type` is non-optional that failure
    /// takes the whole list with it. If the server ever adds an eleventh value
    /// before the app knows it, this is the shape of what happens — and this
    /// test is where to change the decision.
    func testUnknownValueStillThrows() {
        let json = Data("\"COVER_CROPPING\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LogEntryType.self, from: json))
    }
}
