import XCTest
@testable import Agrent

/// `CostEntry.incurredOn` read as an instant OR a bare day (`InstantOrDay`):
/// the data is a day, the spec publishes an instant, and agri-saas is
/// re-typing it as `format: date` (#1443). The app must read both before the
/// wire changes, or the whole Калкулатор cost list fails on the first row.
final class CostDateTests: XCTestCase {

    private func page(incurredOn: String) -> Data {
        Data("""
        {"rows":[{"id":"cst_1","category":"FUEL","amount":120.5,"currency":"EUR",
          "incurredOn":"\(incurredOn)",
          "createdAt":"2026-09-22T08:00:00.000Z","updatedAt":"2026-09-22T08:00:00.000Z"}],
         "totalCount":1,"truncated":false}
        """.utf8)
    }

    /// The wire today: a full instant.
    func testAnInstantIsRead() async throws {
        let costs = try await CostsAPI.decodeList(from: page(incurredOn: "2026-09-22T00:00:00.000Z"))
        XCTAssertEqual(costs.items.first?.incurredOn.date, BgDate.parseInstant("2026-09-22T00:00:00.000Z"))
    }

    /// The wire once re-typed: a bare day — read as that day, not a failed list.
    func testABareDayIsRead() async throws {
        let costs = try await CostsAPI.decodeList(from: page(incurredOn: "2026-09-22"))
        XCTAssertEqual(costs.items.first?.incurredOn.date, BgDate.parseISODay("2026-09-22"))
    }

    /// Neither is still refused, so a broken value is never shown as a date.
    func testNeitherIsRefused() async {
        do {
            _ = try await CostsAPI.decodeList(from: page(incurredOn: "22.09.2026"))
            XCTFail("a value that is neither an instant nor a day decoded")
        } catch {}
    }
}
