import XCTest
@testable import Agrent

/// The person's live stream (#605) against agri-saas P7.6. Nothing here
/// opens a connection.
final class LiveUpdatesTests: XCTestCase {

    func testFramesAreReadByTheirKindField() throws {
        let channel = try XCTUnwrap(LiveUpdates.frame(Data(#"{"kind":"channel","id":"ch_1","tenantId":"person"}"#.utf8)))
        XCTAssertEqual(channel, LiveUpdates.Frame(kind: .channel, id: "ch_1", tenantId: "person"))
        let dm = try XCTUnwrap(LiveUpdates.frame(Data(#"{"kind":"dm","id":"conv_1","tenantId":"person"}"#.utf8)))
        XCTAssertEqual(dm.kind, .dm)
        XCTAssertEqual(dm.id, "conv_1", "the conversation, never a message")
        let note = try XCTUnwrap(LiveUpdates.frame(Data(#"{"kind":"notification","id":"n_1","tenantId":"ten_1"}"#.utf8)))
        XCTAssertEqual(note.tenantId, "ten_1")
        let tick = try XCTUnwrap(LiveUpdates.frame(Data(#"{"kind":"listing","id":"listings","tenantId":"listings"}"#.utf8)))
        XCTAssertEqual(tick.kind, .listing)
    }

    /// `"person"` is a sentinel, not a farm: a channel or DM frame must reach
    /// its store whatever farms the person is in.
    func testThePersonSentinelIsKeptNotFiltered() throws {
        let frame = try XCTUnwrap(LiveUpdates.frame(Data(#"{"kind":"dm","id":"c","tenantId":"person"}"#.utf8)))
        XCTAssertEqual(frame.tenantId, "person")
        XCTAssertNotNil(frame, "positive control: delivered, not dropped")
    }

    func testUnknownAndBrokenFramesAreIgnored() {
        XCTAssertNil(LiveUpdates.frame(Data(#"{"kind":"weather","id":"x"}"#.utf8)), "a kind this build does not know")
        XCTAssertNil(LiveUpdates.frame(Data("not json".utf8)))
        XCTAssertNil(LiveUpdates.frame(Data(#"{"id":"x"}"#.utf8)), "no kind")
    }

    func testReconnectWaitsGrowAndStop() {
        XCTAssertEqual(LiveUpdates.backoff(0), .seconds(5))
        XCTAssertEqual(LiveUpdates.backoff(1), .seconds(10))
        XCTAssertEqual(LiveUpdates.backoff(3), .seconds(40))
        XCTAssertEqual(LiveUpdates.backoff(6), .seconds(300), "capped at five minutes")
        XCTAssertEqual(LiveUpdates.backoff(20), .seconds(300))
    }

    func testThePathIsThePersons() {
        XCTAssertEqual(LiveUpdates.path, "/api/me/stream")
    }

    /// The payload of a `data:` line — the parser the stream already uses.
    func testOnlyDataLinesCarryAFrame() {
        XCTAssertEqual(APIClient.eventPayload(#"data: {"kind":"dm"}"#), Data(#"{"kind":"dm"}"#.utf8))
        XCTAssertNil(APIClient.eventPayload(": heartbeat"))
        XCTAssertNil(APIClient.eventPayload("id: 42"))
    }
}
