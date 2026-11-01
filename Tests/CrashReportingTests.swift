import Sentry
import XCTest
@testable import Agrent

/// Sentry (#494): it starts only from a build that carries a DSN, and what
/// it sends carries no person. Nothing here starts the SDK.
final class CrashReportingTests: XCTestCase {

    /// Only an https address starts it: the empty value every build but
    /// TestFlight's carries, an unexpanded build setting and junk do not.
    func testOnlyABuildWithADSNReports() {
        let key = CrashReporting.infoKey
        XCTAssertNil(CrashReporting.dsn(from: [:]))
        XCTAssertNil(CrashReporting.dsn(from: [key: ""]))
        XCTAssertNil(CrashReporting.dsn(from: [key: "$(AGRENT_SENTRY_DSN)"]))
        XCTAssertNil(CrashReporting.dsn(from: [key: "http://key@o1.ingest.de.sentry.io/2"]))
        XCTAssertNil(CrashReporting.dsn(from: [key: "https://"]))
        XCTAssertEqual(CrashReporting.dsn(from: [key: " https://key@o1.ingest.de.sentry.io/2 "]),
                       "https://key@o1.ingest.de.sentry.io/2")
        XCTAssertNil(CrashReporting.dsn(from: Bundle.main.infoDictionary ?? [:]),
                     "the test build carries a DSN, so the suite would report to Sentry")
    }

    /// Requests, taps and the console never travel; nor does anything with
    /// an address or a screen title, whatever its category.
    func testTheBreadcrumbsKeepNoAddressOrTap() {
        XCTAssertTrue(CrashReporting.keeps("app.lifecycle", data: ["state": "background"]))
        XCTAssertTrue(CrashReporting.keeps("ui.lifecycle", data: nil))
        for dropped in ["http", "touch", "ui.click", "console", "query"] {
            XCTAssertFalse(CrashReporting.keeps(dropped, data: nil), dropped)
        }
        XCTAssertFalse(CrashReporting.keeps("navigation", data: ["to": "/t/ferma/locations/loc_1"]))
        XCTAssertFalse(CrashReporting.keeps("ui.lifecycle", data: ["screen": "X", "Title": "Нива 1"]))
        XCTAssertFalse(CrashReporting.keeps("custom", data: ["URL": "https://app.agrent.bg/x"]))
    }

    /// Every event leaves without its user, request and device name, and
    /// with only the breadcrumbs above.
    func testAnEventLeavesWithoutThePerson() {
        let event = Event(level: .error)
        let user = User(userId: "usr_fixture")
        user.email = "fixture@example.invalid"
        event.user = user
        event.request = SentryRequest()
        event.serverName = "Телефон-фикстура"
        let kept = Breadcrumb(level: .info, category: "app.lifecycle")
        let tap = Breadcrumb(level: .info, category: "touch")
        let request = Breadcrumb(level: .info, category: "http")
        request.setData(value: "https://app.agrent.bg/api/t/ferma/grain/costs", key: "url")
        event.breadcrumbs = [kept, tap, request]

        let sent = CrashReporting.scrub(event)
        XCTAssertNil(sent.user)
        XCTAssertNil(sent.request)
        XCTAssertNil(sent.serverName)
        XCTAssertEqual(sent.breadcrumbs?.map(\.category), ["app.lifecycle"])
    }
}
