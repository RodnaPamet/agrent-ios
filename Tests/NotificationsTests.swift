import XCTest
@testable import Agrent

/// «Известия» (#471): the list as the server sends it, the unread count and
/// marking one read, where a notification leads, and where the surface lives.
final class NotificationsTests: XCTestCase {

    private nonisolated static func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: NotificationsTests.self)
            .url(forResource: "notifications-list", withExtension: "json")))
    }

    func testThePathsHaveNoQuery() {
        XCTAssertTrue(NotificationsAPI.listPath.hasSuffix("/notifications"))
        XCTAssertTrue(NotificationsAPI.readPath("n 1").hasSuffix("/notifications/n%201"))
        XCTAssertFalse(NotificationsAPI.listPath.contains("?"))
        XCTAssertTrue(NotificationsAPI.listPath.hasPrefix(FarmPath.root))
    }

    /// A bare array; a row without an id is dropped, an odd field costs the
    /// field, and a title is never empty.
    func testTheListDecodes() async throws {
        let items = try await NotificationsAPI.decodeList(from: Self.fixture())
        XCTAssertEqual(items.map(\.id), ["ntf_fixture_task", "ntf_fixture_exchange", "ntf_fixture_lease"])
        XCTAssertEqual(items.filter { !$0.read }.count, 2)
        XCTAssertEqual(items[0].link(inFarm: "agrent"), .task(farm: "agrent", id: "tsk_fixture_2"))
        XCTAssertEqual(items[1].link(inFarm: "agrent"), .thread(farm: "agrent", id: "thr_synthetic_1"))
        XCTAssertNil(items[2].link(inFarm: "agrent"), "no link: the row is only marked read")

        let odd = #"[{"title":"без id"},{"id":"x","read":"yes","title":"  "}]"#
        let rows = try await NotificationsAPI.decodeList(from: Data(odd.utf8))
        XCTAssertEqual(rows.map(\.id), ["x"])
        XCTAssertFalse(rows[0].read, "an odd `read` reads as unread, never as the reason the list fails")
        XCTAssertEqual(rows[0].title, "Известие")
    }

    /// agri-saas #2512's third shape (#488): an absolute https address a
    /// farm's automation rule wrote opens in Safari's view; one on this app's
    /// own server opens the screen its path names; anything else opens
    /// nothing.
    func testAnAddressOutsideTheAppIsAWebPage() {
        func row(_ link: String?) -> AppNotification {
            AppNotification(id: "n", type: nil, title: "Известие", message: nil, linkUrl: link, read: false, createdAt: nil)
        }
        let document = row("https://docs.example.org/fixture/report.pdf?v=2")
        XCTAssertNil(document.link(inFarm: "agrent"))
        XCTAssertEqual(document.webPage(inFarm: "agrent")?.absoluteString, "https://docs.example.org/fixture/report.pdf?v=2")

        let own = row("https://app.agrent.bg/t/agrent/farm-tasks/tsk_fixture_2")
        XCTAssertEqual(own.link(inFarm: "agrent"), .task(farm: "agrent", id: "tsk_fixture_2"))
        XCTAssertNil(own.webPage(inFarm: "agrent"), "a screen the app shows is never the web's")
        XCTAssertEqual(row("HTTPS://APP.AGRENT.BG/t/agrent/locations/loc_1").link(inFarm: nil),
                       .location(farm: "agrent", id: "loc_1"))
        XCTAssertEqual(row("https://app.agrent.bg/t/agrent/settings").webPage(inFarm: "agrent")?.host,
                       "app.agrent.bg", "a web page of the app's own server the phone has no screen for")

        for refused in ["http://docs.example.org/report.pdf", "javascript:alert(1)", "bg.agrent.app://x",
                        "mailto:fixture@example.org", "https://app.agrent.bg@docs.example.org/x",
                        "https:///no-host", "//docs.example.org/x", "", "не е адрес"] {
            XCTAssertNil(row(refused).webPage(inFarm: "agrent"), refused)
        }
        XCTAssertNil(row("https://app.agrent.bg:8443/t/agrent/farm-tasks/t").link(inFarm: "agrent"),
                     "another port is not this app's server")
        XCTAssertNil(row(nil).webPage(inFarm: "agrent"))
    }

    /// Opened: read on the phone at once and told to the server; a refusal
    /// reads the list again, whose answer stands.
    @MainActor
    func testMarkingReadAndARefusal() async throws {
        let items = try await NotificationsAPI.decodeList(from: Self.fixture())
        @MainActor final class Calls { var reads = 0; var marked: [String] = []; var refuse = false }
        let calls = Calls()
        let store = NotificationsStore(
            read: { await MainActor.run { calls.reads += 1 }; return items },
            markRead: { id in
                try await MainActor.run {
                    calls.marked.append(id)
                    if calls.refuse { throw URLError(.notConnectedToInternet) }
                }
            },
            openFarm: { "agrent" })
        await store.refresh()
        XCTAssertEqual(store.unreadCount, 2)
        await store.markRead(items[0])
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(calls.marked, ["ntf_fixture_task"])

        calls.refuse = true
        await store.markRead(items[1])
        XCTAssertEqual(calls.reads, 2, "a refusal reads the list again")
        XCTAssertEqual(store.unreadCount, 2, "the server's answer stands: both unread in its list")

        await store.markRead(items[2])
        XCTAssertEqual(calls.marked.count, 2, "an already-read row is not sent again")
        store.reset()
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testItIsASurfaceInTheMenuNotTheOperators() {
        XCTAssertEqual(AppSurface.notifications.rawValue, "/notifications")
        XCTAssertEqual(AppSurface.notifications.label, "Известия")
        XCTAssertFalse(AppSurface.notifications.isOperatorAllowed)
        XCTAssertFalse(AppSurface.fallback.contains(.notifications), "in the menu by default")
        XCTAssertEqual(MessagingPolicy.counted("Известия", unread: 2), "Известия (2)")
        XCTAssertEqual(MessagingPolicy.counted("Известия", unread: 0), "Известия")
    }

    /// The menu and the bar both show the count, from the one store.
    func testTheCountReachesTheMenuAndTheBar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let menu = try String(contentsOf: root.appendingPathComponent("Agrent/Design/AppMenu.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("Agrent/AgrentApp.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("case .notifications: MessagingPolicy.counted(surface.label, unread: notifications.unreadCount)"))
        XCTAssertTrue(app.contains("case .notifications: notifications.unreadCount"))
        XCTAssertTrue(app.contains("case .exchange: unread.count"), "positive control: Борса's count is still there")
    }
}
