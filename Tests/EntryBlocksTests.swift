import XCTest
@testable import Agrent

/// «Нов запис»'s blocks (#254): the hand-written entry's `LogLocation` links,
/// sent as `locationIds` on POST /journal. That field is in the live spec, so
/// this change touches only the phone.
final class EntryBlocksTests: XCTestCase {

    private func body(_ draft: CreateLogEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    }

    func testChosenBlocksAreSentAsLocationIds() throws {
        let draft = CreateLogEntry(type: .activity, title: "Обход", locationIds: ["loc_1", "loc_2"])
        XCTAssertEqual(try body(draft)["locationIds"] as? [String], ["loc_1", "loc_2"])
    }

    /// No block chosen leaves the key out, so an unlinked entry's body is
    /// exactly the one the app sent before #254.
    func testNoBlockLeavesTheKeyOut() throws {
        let sent = try body(CreateLogEntry(type: .activity, title: "Обход"))
        XCTAssertNil(sent["locationIds"])
        XCTAssertEqual(Set(sent.keys), ["type", "status", "title"])
    }

    /// The check-mark row moved to the design system, so the close form's
    /// weeds and the entry's blocks are one control. Read from the sources,
    /// as no runtime hook tells two rows apart.
    func testTheCloseFormAndTheEntryFormShareOneChoiceRow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        XCTAssertTrue(try source("Agrent/Design/ChoiceRow.swift").contains("struct ChoiceRow: View"))
        XCTAssertTrue(try source("Agrent/Journal/NewEntryView.swift").contains("ChoiceRow("))
        let close = try source("Agrent/Tasks/CloseTaskSheet.swift")
        XCTAssertTrue(close.contains("ChoiceRow("), "positive control: the close form still uses it")
        XCTAssertFalse(close.contains("struct ChoiceRow"), "the close form kept a private copy")
    }
}
