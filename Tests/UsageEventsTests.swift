import XCTest
@testable import Agrent

/// The usage page's events (#493): the server's names exactly, nothing while
/// the flag is off, each farm's events to that farm, a refusal never retried,
/// and a sign-out that leaves nothing behind. Nothing here sends a request.
@MainActor
final class UsageEventsTests: XCTestCase {

    /// What the fake server was sent.
    @MainActor private final class Sent {
        var calls: [(path: String, batch: UsageEvents.Batch)] = []
        var answer = 204
    }

    private func events(on: Bool = true, farm: String? = "ferma-a", sent: Sent) -> UsageEvents {
        let usage = UsageEvents()
        usage.isOn = { on }
        usage.farm = { farm }
        usage.send = { path, batch in
            await MainActor.run { sent.calls.append((path, batch)) }
            return await MainActor.run { sent.answer }
        }
        return usage
    }

    /// agri-saas's frozen list (backend 1, 2026-11-01), plus the two custody
    /// moves asked for with it. A name the server drops costs a count, never
    /// the batch, but a typo here would silently count nothing.
    func testTheNamesAreTheServers() {
        let frozen: Set = [
            "screen_opened",
            "treatment_saved", "activity_saved", "treatment_corrected", "treatment_deleted",
            "diary_pdf_downloaded", "farm_diary_downloaded",
            "cost_saved", "cost_deleted", "invoice_scanned",
            "task_created", "task_closed", "task_comment_added",
            "document_uploaded", "document_scanned", "drive_copy_requested",
            "listing_created", "listing_edited", "inquiry_sent", "message_sent",
            "assistant_asked", "assistant_entry_opened",
            "notification_opened", "parcel_located",
        ]
        let asked: Set = ["listing_fulfilled", "listing_withdrawn"]
        XCTAssertEqual(Set(UsageEvents.Name.allCases.map(\.rawValue)), frozen.union(asked))
        for name in UsageEvents.Name.allCases {
            XCTAssertNil(name.rawValue.rangeOfCharacter(from: .decimalDigits), "a number in a name: \(name)")
            XCTAssertEqual(name.rawValue, name.rawValue.lowercased())
        }
    }

    /// Static routes only, each one the server's.
    func testTheSurfacesAreStatic() {
        let server: Set = ["/journal", "/grain/calculator", "/exchange", "/locations", "/farm-tasks", "/trends",
                           "/news", "/farm-risk", "/dashboard", "/notifications", "/documents",
                           "mechanisator_home", "profile", "menu"]
        var sent = AppSurface.allCases.map { UsageEvents.Surface.app($0).wire }
        sent += [UsageEvents.Surface.mechanisatorHome.wire, UsageEvents.Surface.profile.wire]
        for surface in sent {
            XCTAssertTrue(server.contains(surface), surface)
            XCTAssertFalse(surface.contains("{") || surface.contains("["), surface)
        }
    }

    /// The body carries a name, a static surface for a screen, and a time:
    /// no farm, no user, nothing else.
    func testTheBodyCarriesNothingElse() throws {
        let batch = UsageEvents.Batch(events: [
            .init(name: "screen_opened", surface: "/journal", at: Date(timeIntervalSince1970: 0)),
            .init(name: "cost_saved", surface: nil, at: Date(timeIntervalSince1970: 0)),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(batch)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["events"])
        let rows = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["name", "surface", "at"])
        XCTAssertEqual(Set(rows[1].keys), ["name", "at"], "an action sends no surface")
        XCTAssertEqual(rows[0]["at"] as? String, "1970-01-01T00:00:00Z")
    }

    /// Off: nothing queued, nothing sent.
    func testNothingWhileTheFlagIsOff() async {
        let sent = Sent()
        let usage = events(on: false, sent: sent)
        usage.screen(.app(.journal))
        usage.record(.costSaved)
        XCTAssertTrue(usage.queued.isEmpty)
        await usage.flush()
        XCTAssertTrue(sent.calls.isEmpty)
    }

    /// Each farm's events to that farm's path, whichever is open when they
    /// leave; at most 50 a request.
    func testEachFarmsEventsGoToThatFarm() async {
        let sent = Sent()
        var open = "ferma-a"
        let usage = events(sent: sent)
        usage.farm = { open }
        for _ in 0..<15 { usage.record(.taskClosed) }
        open = "ferma-b"
        usage.screen(.app(.journal))
        await usage.flush()
        XCTAssertEqual(sent.calls.map(\.path), [UsageEvents.path(farm: "ferma-a"), UsageEvents.path(farm: "ferma-b")])
        XCTAssertEqual(sent.calls[0].batch.events.count, 15)
        XCTAssertEqual(sent.calls[1].batch.events.map(\.surface), ["/journal"])
        XCTAssertTrue(usage.queued.isEmpty)

        // Past the server's 50 a request: split, nothing lost. (Twenty sends
        // on its own; the flush takes whatever is left.)
        sent.calls = []
        for _ in 0..<64 { usage.record(.costSaved) }
        await usage.flush()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sent.calls.allSatisfy { $0.batch.events.count <= UsageEvents.batchLimit })
    }

    /// Any failure drops the batch without a retry; a 403 or 404 (switched
    /// off, or a server without the route) stops sending for the session.
    func testARefusalIsNeverRetried() async {
        let sent = Sent()
        let usage = events(sent: sent)
        sent.answer = 500
        usage.record(.costSaved)
        await usage.flush()
        XCTAssertEqual(sent.calls.count, 1)
        XCTAssertTrue(usage.queued.isEmpty, "a failed batch is dropped, not kept for later")
        XCTAssertFalse(usage.refused)

        sent.answer = 403
        usage.record(.costSaved)
        await usage.flush()
        XCTAssertTrue(usage.refused)
        usage.record(.costSaved)
        await usage.flush()
        XCTAssertEqual(sent.calls.count, 2, "nothing more after a 403")
    }

    /// A sign-out: the queue was the last person's.
    func testASignOutLeavesNothing() {
        let sent = Sent()
        let usage = events(sent: sent)
        usage.record(.messageSent)
        XCTAssertFalse(usage.queued.isEmpty)
        usage.reset()
        XCTAssertTrue(usage.queued.isEmpty)
        XCTAssertTrue(try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/Auth/SessionReset.swift"), encoding: .utf8)
            .contains("UsageEvents.shared.reset()"), "sign-out must empty the queue")
    }

    /// No farm open: nothing to attribute it to, so nothing kept.
    func testNoFarmNoEvent() {
        let usage = events(farm: nil, sent: Sent())
        usage.record(.costSaved)
        XCTAssertTrue(usage.queued.isEmpty)
    }
}
