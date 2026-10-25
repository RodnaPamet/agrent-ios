import XCTest
@testable import Agrent

/// «Дневник (PDF)» (#246, #436): «ДНЕВНИК НА СТОПАНСТВОТО» from
/// `POST /reports/campaign-diary?campaign=…`. NOTHING HERE ASKS THE SERVER
/// FOR ONE: the request, the file it becomes and the session it travels on
/// are each decided above the wire.
final class FarmRecordTests: XCTestCase {

    private var sofia: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }

    /// A campaign with nothing in it is its own 404 (agri-saas, as the
    /// per-block register's since #2183): told apart from a missing farm,
    /// which is an error.
    func testAnEmptyCampaignIsItsOwnAnswer() {
        XCTAssertTrue(FarmRecordAPI.isEmptyPeriod(APIClient.APIError.http(
            status: 404, code: "REGISTER_EMPTY_FOR_PERIOD", message: nil)))
        XCTAssertFalse(FarmRecordAPI.isEmptyPeriod(APIClient.APIError.http(status: 404, code: nil, message: nil)),
                       "a bare 404 is something missing, not an empty campaign")
        XCTAssertFalse(FarmRecordAPI.isEmptyPeriod(APIClient.APIError.http(
            status: 404, code: "TENANT_NOT_FOUND", message: nil)))
        XCTAssertFalse(FarmRecordAPI.isEmptyPeriod(URLError(.notConnectedToInternet)))
        XCTAssertEqual(FarmRecordAPI.emptyCampaignText, "Няма записи за тази кампания.")
    }

    /// The campaign is the query, `YYYY-YYYY` with consecutive years.
    func testThePathCarriesTheCampaign() {
        let path = FarmRecordAPI.campaignPath(.init(startYear: 2024))
        XCTAssertTrue(path.hasSuffix("/reports/campaign-diary?campaign=2024-2025"), path)
    }

    /// 1 October to 30 September, by the farm's own day: 30 September is
    /// still the campaign before, 1 October the next.
    func testACampaignStartsOnTheFirstOfOctober() {
        func campaign(_ instant: String) -> Int {
            FarmRecordAPI.Campaign.containing(BgDate.parseInstant(instant)!, calendar: sofia).startYear
        }
        XCTAssertEqual(campaign("2025-09-30T12:00:00.000Z"), 2024)
        XCTAssertEqual(campaign("2025-10-01T12:00:00.000Z"), 2025)
        XCTAssertEqual(campaign("2026-02-14T12:00:00.000Z"), 2025)
        // Midnight in Sofia, still 30 September in UTC: Bulgaria's day.
        XCTAssertEqual(campaign("2025-09-30T21:30:00.000Z"), 2025)
    }

    /// The current campaign first, then the four before it.
    func testTheRecentCampaignsAreTheCurrentOneFirst() {
        let now = BgDate.parseInstant("2026-10-25T12:00:00.000Z")!
        let list = FarmRecordAPI.Campaign.recent(now: now, calendar: sofia)
        XCTAssertEqual(list.map(\.parameter), ["2026-2027", "2025-2026", "2024-2025", "2023-2024", "2022-2023"])
        XCTAssertEqual(list.first?.label, "Кампания 2026–2027")
        XCTAssertEqual(FarmRecordSheet.years(list[2]), "2024–2025")
    }

    func testTheFileIsNamedAsServedOrByItsCampaign() {
        let campaign = FarmRecordAPI.Campaign(startYear: 2024)
        XCTAssertEqual(FarmRecordAPI.fileName("dnevnik-x.pdf", fallback: FarmRecordAPI.fallbackName(campaign)),
                       "dnevnik-x.pdf")
        XCTAssertEqual(FarmRecordAPI.fileName(nil, fallback: FarmRecordAPI.fallbackName(campaign)),
                       "dnevnik-na-stopanstvoto-2024-2025.pdf")
        // Quick Look reads the type off the name.
        XCTAssertEqual(FarmRecordAPI.fileName("register", fallback: "x.pdf"), "register.pdf")
    }

    /// One treatment's pages fall back to the name the server gives them.
    func testATreatmentsFileFallsBackToItsOwnName() {
        XCTAssertEqual(FarmRecordAPI.fileName(nil, fallback: "dnevnik-h1.pdf"), "dnevnik-h1.pdf")
        XCTAssertEqual(FarmRecordAPI.fileName("served", fallback: "dnevnik-h1.pdf"), "served.pdf")
    }

    /// Both ДНЕВНИК documents are kept one way: only a PDF, only the latest,
    /// and gone with the sheet.
    func testOnlyTheLatestPDFIsKeptAndTheSheetTakesItAway() throws {
        defer { FarmRecordAPI.removeGenerated() }
        XCTAssertThrowsError(try FarmRecordAPI.keep(Data(#"{"ok":true}"#.utf8), named: "x.pdf")) {
            XCTAssertEqual($0 as? FarmRecordAPI.Failure, .notAPDF)
        }
        let first = try FarmRecordAPI.keep(Data("%PDF-1.7\n1".utf8), named: "first.pdf")
        let second = try FarmRecordAPI.keep(Data("%PDF-1.7\n2".utf8), named: "second.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "an earlier ДНЕВНИК was kept")
        XCTAssertEqual(try Data(contentsOf: second), Data("%PDF-1.7\n2".utf8))
        FarmRecordAPI.removeGenerated()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    /// A 200 that is not a PDF is refused rather than written as one.
    func testOnlyAPDFIsAPDF() {
        XCTAssertTrue(FarmRecordAPI.isPDF(Data("%PDF-1.7\n…".utf8)))
        XCTAssertFalse(FarmRecordAPI.isPDF(Data(#"{"fileRecordId":"f1"}"#.utf8)))
        XCTAssertFalse(FarmRecordAPI.isPDF(Data()))
    }

    // MARK: - Content-Disposition

    func testTheServersFileNameIsRead() {
        XCTAssertEqual(APIClient.fileName(contentDisposition: #"attachment; filename="dnevnik-2026.pdf""#),
                       "dnevnik-2026.pdf")
        XCTAssertEqual(APIClient.fileName(contentDisposition: "attachment; filename=plain.pdf"), "plain.pdf")
    }

    /// RFC 6266's extended form first — a Cyrillic name can only travel that way.
    func testTheExtendedFormWins() {
        XCTAssertEqual(
            APIClient.fileName(contentDisposition:
                #"attachment; filename="fallback.pdf"; filename*=UTF-8''%D0%B4%D0%BD%D0%B5%D0%B2%D0%BD%D0%B8%D0%BA.pdf"#),
            "дневник.pdf")
    }

    /// A name is a name, never a place to write to.
    func testAPathInTheNameIsCutToItsLastComponent() {
        XCTAssertEqual(APIClient.fileName(contentDisposition: #"attachment; filename="../../etc/passwd""#),
                       "passwd")
        XCTAssertNil(APIClient.fileName(contentDisposition: "attachment"))
        XCTAssertNil(APIClient.fileName(contentDisposition: nil))
    }

    // MARK: - The session it travels on

    /// The ordinary session in every way but how long it waits: the server
    /// builds the document before it sends a byte, on a 60-second budget.
    func testTheDocumentSessionWaitsForTheServerToBuildIt() {
        let document = APIClient.documentSessionConfiguration()
        let ordinary = APIClient.sessionConfiguration()
        XCTAssertEqual(document.timeoutIntervalForRequest, 90)
        XCTAssertGreaterThan(document.timeoutIntervalForRequest, 60, "shorter than the server's own budget")
        XCTAssertNil(document.urlCache, "a document reaching Cache.db (#134)")
        XCTAssertEqual(document.waitsForConnectivity, ordinary.waitsForConnectivity)
        XCTAssertEqual(ordinary.timeoutIntervalForRequest, 15, "positive control: the ordinary one is unchanged")
    }
}
