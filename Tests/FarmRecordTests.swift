import XCTest
@testable import Agrent

/// «Дневник (PDF)» (#246): the БАБХ ДНЕВНИК from
/// `POST /locations/{id}/farm-record`. NOTHING HERE ASKS THE SERVER FOR ONE —
/// the request, the file it becomes and the session it travels on are each
/// decided above the wire.
final class FarmRecordTests: XCTestCase {

    private let request = FarmRecordAPI.Request(from: "2026-01-01", to: "2026-10-09")

    func testThePathIsTheLocationsFarmRecord() {
        XCTAssertTrue(FarmRecordAPI.path("loc 1").hasSuffix("/locations/loc%201/farm-record"),
                      FarmRecordAPI.path("loc 1"))
    }

    /// The period as days, and NEVER `save` — that files the PDF in the
    /// register and answers JSON instead of the document.
    func testTheBodyIsThePeriodAndNothingElse() throws {
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(body["from"] as? String, "2026-01-01")
        XCTAssertEqual(body["to"] as? String, "2026-10-09")
        XCTAssertEqual(Set(body.keys), ["from", "to"])
    }

    /// The web's first offer: 1 January of this year to today.
    func testThePeriodStartsOnTheFirstOfJanuary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        let now = BgDate.parseInstant("2026-10-09T12:00:00.000Z")!
        let period = FarmRecordAPI.defaultPeriod(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: period.from),
                       DateComponents(year: 2026, month: 1, day: 1))
        XCTAssertEqual(period.to, now)
    }

    func testTheFileIsNamedAsServedOrAsTheWebWouldName() {
        XCTAssertEqual(FarmRecordAPI.fileName("dnevnik-x.pdf", for: request), "dnevnik-x.pdf")
        XCTAssertEqual(FarmRecordAPI.fileName(nil, for: request), "dnevnik-2026-01-01_2026-10-09.pdf")
        // Quick Look reads the type off the name.
        XCTAssertEqual(FarmRecordAPI.fileName("register", for: request), "register.pdf")
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
