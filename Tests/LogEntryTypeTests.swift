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
            Set(LogEntryType.selectable.map(\.rawValue)),
            Set(serverRawValues),
            "app enum and server enum have diverged"
        )
    }

    /// `OTHER` was invented client-side and the server would have rejected a
    /// create using it.
    func testInventedCaseIsGone() {
        XCTAssertFalse(LogEntryType.selectable.map(\.rawValue).contains("OTHER"))
    }

    func testEveryCaseHasADistinctBulgarianLabel() {
        let labels = LogEntryType.selectable.map(\.label)
        for (type, label) in zip(LogEntryType.selectable, labels) {
            XCTAssertFalse(label.isEmpty, "\(type.rawValue) has no label")
            XCTAssertNotEqual(label, type.rawValue, "\(type.rawValue) label is untranslated")
        }
        XCTAssertEqual(Set(labels).count, labels.count, "two cases share a label")
    }

    /// THE DECISION CHANGED HERE, 2026-09-23.
    ///
    /// This used to assert that an unrecognised type THROWS, documenting
    /// that an eleventh server value would take the whole journal with it.
    /// It now asserts it degrades. See `LogEntryType`'s header for why the
    /// asymmetry beats the frequency.
    func testAnUnknownValueDegradesInsteadOfThrowing() throws {
        let json = Data("\"COVER_CROPPING\"".utf8)
        let decoded = try JSONDecoder().decode(LogEntryType.self, from: json)
        XCTAssertEqual(decoded, .unknown)
        XCTAssertEqual(decoded.label, "Друг вид")
        XCTAssertNotEqual(decoded.label, decoded.rawValue, "raw value reached a screen")
    }

    /// The point of the change: ONE unknown row must not cost the others.
    /// This is the failure that was possible before — a whole legally
    /// required register rendering as nothing.
    func testOneUnknownRowDoesNotTakeTheListWithIt() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = """
        [{"id":"a","type":"ACTIVITY","status":"DONE","title":"One",
          "occurredAt":"2026-09-11T10:00:00Z"},
         {"id":"b","type":"COVER_CROPPING","status":"DONE","title":"Two",
          "occurredAt":"2026-09-12T10:00:00Z"},
         {"id":"c","type":"HARVEST","status":"DONE","title":"Three",
          "occurredAt":"2026-09-13T10:00:00Z"}]
        """
        let rows = try decoder.decode([LogEntry].self, from: Data(list.utf8))
        XCTAssertEqual(rows.count, 3, "an unknown type blanked the list")
        XCTAssertEqual(rows.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(rows[1].type, .unknown)
    }

    /// `.unknown` is readable and NOT offerable. Its raw value is one the
    /// server would reject on a create, so a picker that included it would
    /// build a request guaranteed to fail.
    func testUnknownIsNotSelectable() {
        XCTAssertFalse(LogEntryType.selectable.contains(.unknown))
        XCTAssertEqual(LogEntryType.selectable.count, serverRawValues.count)
        XCTAssertEqual(Set(LogEntryType.selectable.map(\.rawValue)), Set(serverRawValues))
    }

    /// Case-insensitive, via `LenientDecodable`.
    func testKnownValuesStillDecodeExactly() throws {
        for raw in serverRawValues {
            let decoded = try JSONDecoder().decode(
                LogEntryType.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(decoded.rawValue, raw)
            XCTAssertNotEqual(decoded, .unknown, "\(raw) fell through to unknown")
        }
    }
}

/// The server composes a title for auto-generated entries and now sends a
/// descriptor beside it: `titleKey` plus `titleParams`.
///
/// THIS APP DELIBERATELY IGNORES BOTH, and that is a decision rather than
/// an omission — so it gets a test, because "we chose not to read these"
/// is otherwise indistinguishable from "nobody noticed them".
///
/// `title` is always populated and is now Bulgarian, so doing nothing
/// renders the right string. Resolving the key would duplicate work the
/// server has already done, for a second language this app does not have
/// — every literal in it is hard-coded Bulgarian by the same decision
/// recorded in `UserMessage`.
///
/// It would also introduce a failure the current code cannot have. An
/// operator editing a title clears `titleKey` server-side, so a client
/// that resolved a key it had cached, or resolved one while rendering a
/// stale row, would silently paint over somebody's correction. Not
/// reading the field cannot do that.
final class LogEntryTitleDescriptorTests: XCTestCase {

    /// The new shape, verbatim from the server side's description.
    private let withDescriptor = """
    {"id":"e1","type":"INPUT_APPLICATION","status":"DONE",
     "title":"Generic MAP 11-52-0 — 15655-19",
     "occurredAt":"2026-09-11T10:00:00.000Z","version":3,
     "titleKey":"journal.autoTitle.inputApplication",
     "titleParams":{"product":"Generic MAP 11-52-0","parcel":"15655-19"}}
    """

    private func decode(_ json: String) throws -> LogEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LogEntry.self, from: Data(json.utf8))
    }

    /// The fields arrive on the LIST response, which is the screen the
    /// owner opens most. A strict decoder here would blank every row
    /// rather than one, so this is the guard that matters.
    func testTheNewFieldsDoNotBreakTheDecode() throws {
        let entry = try decode(withDescriptor)
        XCTAssertEqual(entry.title, "Generic MAP 11-52-0 — 15655-19")
        XCTAssertEqual(entry.id, "e1")
        XCTAssertEqual(entry.version, 3)
    }

    /// A person-edited row has `titleKey: null`, and its `title` is the
    /// only correct string. Rendering `title` unconditionally is right in
    /// both worlds — which is the whole argument for not reading the key.
    func testAPersonEditedTitleIsRenderedAsSent() throws {
        let entry = try decode("""
        {"id":"e2","type":"INPUT_APPLICATION","status":"DONE",
         "title":"Пръскане след дъжда","occurredAt":"2026-09-11T10:00:00.000Z",
         "titleKey":null,"titleParams":null}
        """)
        XCTAssertEqual(entry.title, "Пръскане след дъжда")
    }

    /// And the old shape, with neither field, still decodes — the deploy
    /// is not instantaneous and a cached response predates it.
    func testTheOldShapeStillDecodes() throws {
        let entry = try decode("""
        {"id":"e3","type":"ACTIVITY","status":"DONE","title":"One",
         "occurredAt":"2026-09-11T10:00:00.000Z"}
        """)
        XCTAssertEqual(entry.title, "One")
        XCTAssertNil(entry.version)
    }
}
