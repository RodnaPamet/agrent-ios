import XCTest
@testable import Agrent

/// An invoice read into expenses (#482, owner 2026-10-31): the server's
/// answer, «От фактура»'s rows, and the sheet «Запиши» posts. Nothing here
/// reaches a server.
@MainActor
final class InvoiceTests: XCTestCase {

    private let answer = #"""
    {"invoiceFileId":"file_synthetic",
     "lines":[
       {"category":"FUEL","amount":"127.82","currency":"EUR","incurredOn":"2026-10-20",
        "supplier":"Синтетичен доставчик ЕООД","description":"250,00 лв. · Фактура № 1 · Дизел",
        "invoiceFileId":"file_synthetic","commodityCanonical":null,"allocationBasis":null},
       {"category":"FERTILIZER","amount":540,"currency":"EUR","incurredOn":"2026-10-20",
        "supplier":"Синтетичен доставчик ЕООД","description":"Амониева селитра",
        "invoiceFileId":"file_synthetic","commodityCanonical":"wheat","allocationBasis":"CROP"},
       {"category":"SEED","amount":"not a number"}
     ],
     "warnings":[{"code":"INVOICE_LINES_TRUNCATED","params":{"found":40,"proposed":25}}]}
    """#

    private func scan() async throws -> InvoiceScan {
        try await APIClient.shared.decode(Data(answer.utf8), as: InvoiceScan.self)
    }

    private let wheat = CropChoice(commodity: "wheat", areaDca: 1000)
    private let today = BgDate.parseInstantOrDay("2026-10-31")!

    // MARK: - The answer

    /// One odd line costs itself and is said; the rest of the invoice stands.
    func testTheAnswerDecodesAndAnOddLineIsSaid() async throws {
        let scan = try await scan()
        XCTAssertEqual(scan.invoiceFileId, "file_synthetic")
        XCTAssertEqual(scan.lines.count, 2)
        XCTAssertEqual(scan.lines[0].amount.value, Decimal(string: "127.82", locale: WireDecimal.wireLocale))
        XCTAssertEqual(scan.lines[1].amount.value, 540, "a number reads as well as a string")
        XCTAssertEqual(scan.warnings.map(\.code), ["INVOICE_LINES_TRUNCATED", InvoiceWarning.unreadLines])
    }

    // MARK: - «От фактура»

    func testTheRowsAreTheLinesAsRead() async throws {
        let review = InvoiceReview(try await scan(), crops: [wheat], today: today)
        XCTAssertEqual(review.rows.count, 2)
        XCTAssertEqual(review.rows[0].category, .fuel)
        XCTAssertEqual(review.rows[0].amountText, "127,82")
        XCTAssertEqual(review.rows[0].attribution, .farm, "no attribution read: the whole farm")
        XCTAssertEqual(review.rows[0].note, "250,00 лв. · Фактура № 1 · Дизел", "the lev original kept in the note")
        XCTAssertEqual(review.rows[1].attribution, .crop("wheat"))
        XCTAssertEqual(InvoiceReview.label(.crop("wheat")), "Пшеница")
        XCTAssertEqual(InvoiceReview.label(.farm), "Общи (за цялото стопанство)")
        XCTAssertEqual(BgDate.isoDay(review.rows[0].incurredOn), "2026-10-20")
    }

    /// A crop the farm has no land for is not offered, so the line starts
    /// over the whole farm; with no crops known yet, the reader's stands.
    func testACropWithoutLandStartsAsTheWholeFarm() async throws {
        let maize = CropChoice(commodity: "maize", areaDca: 500)
        let read = try await scan()
        XCTAssertEqual(InvoiceReview(read, crops: [maize], today: today).rows[1].attribution, .farm)
        XCTAssertEqual(InvoiceReview(read, crops: [], today: today).rows[1].attribution, .crop("wheat"))
    }

    /// The batch's own bound, never more: the warning says the rest.
    func testNeverMoreThanTheBatchTakes() async throws {
        let line = try await APIClient.shared.decode(Data(#"{"category":"FUEL","amount":"1"}"#.utf8),
                                                     as: InvoiceLine.self)
        let many = InvoiceScan(invoiceFileId: "f", lines: Array(repeating: line, count: 30), warnings: [])
        XCTAssertEqual(InvoiceReview(many, crops: [], today: today).rows.count, InvoiceReview.maxLines)
        XCTAssertEqual(InvoiceReview(many, crops: [], today: today).rows[0].incurredOn, today,
                       "an unread date starts as today")
    }

    // MARK: - The sheet

    /// Over the whole farm is `HOLDING` and nothing else of attribution; on
    /// a crop is `CROP` with the crop and a TOTAL — no rate, no place
    /// (agri-saas #2543's answer). Every line points at the invoice.
    func testTheSheetBooksEachLineAsTheBatchTakesIt() async throws {
        let review = InvoiceReview(try await scan(), crops: [wheat], today: today)
        let sheet = try XCTUnwrap(review.sheet)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sheet)) as? [String: Any]
        let lines = try XCTUnwrap(body?["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 2)

        let farm = lines[0]
        XCTAssertEqual(farm["allocationBasis"] as? String, "HOLDING")
        XCTAssertNil(farm["commodityCanonical"])
        XCTAssertEqual(farm["currency"] as? String, "EUR")
        XCTAssertEqual(farm["incurredOn"] as? String, "2026-10-20")
        XCTAssertEqual(farm["invoiceFileId"] as? String, "file_synthetic")
        XCTAssertEqual((farm["amount"] as? NSNumber)?.decimalValue, Decimal(string: "127.82"))

        let crop = lines[1]
        XCTAssertEqual(crop["allocationBasis"] as? String, "CROP")
        XCTAssertEqual(crop["commodityCanonical"] as? String, "wheat")
        XCTAssertNil(crop["amountPerDca"], "a total, not a rate")
        for place in ["plantingId", "parcelId", "locationId", "allocationParcelIds"] {
            XCTAssertNil(crop[place], "\(place) is refused on a CROP line")
        }
        XCTAssertEqual(crop["invoiceFileId"] as? String, "file_synthetic")
    }

    func testNothingGoesUntilEveryRowReads() async throws {
        var review = InvoiceReview(try await scan(), crops: [wheat], today: today)
        review.rows[0].amountText = "абв"
        XCTAssertNil(review.sheet)
        XCTAssertEqual(review.problems, [.amountUnreadable(row: 0)])
        review.rows[0].amountText = "0"
        XCTAssertEqual(review.problems, [.amountOutOfRange(row: 0)])
        review.rows[0].amountText = "1 250,50"
        XCTAssertTrue(review.problems.isEmpty)
        review.rows[1].category = .unknown
        XCTAssertEqual(review.problems, [.categoryMissing(row: 1)])
        review.rows.removeAll()
        XCTAssertEqual(review.problems, [.noLines])
    }

    // MARK: - Words and wire

    func testEverySentenceIsBulgarian() {
        var sentences = [InvoiceReview.checkFirst]
        sentences += [InvoiceWarning(code: "INVOICE_LINES_TRUNCATED", params: ["found": 40, "proposed": 25]),
                      InvoiceWarning(code: "INVOICE_LINES_UNREADABLE", params: ["count": 3]),
                      InvoiceWarning(code: "INVOICE_LINE_FOREIGN_CURRENCY", params: ["count": 1]),
                      InvoiceWarning(code: "INVOICE_LINE_AMOUNT_UNREADABLE", params: ["count": 2]),
                      InvoiceWarning(code: InvoiceWarning.unreadLines, params: ["count": 1]),
                      InvoiceWarning(code: "INVOICE_LINES_TRUNCATED"),
                      InvoiceWarning(code: "SOMETHING_NEW")].map(InvoiceReview.text)
        sentences += [InvoiceReview.Problem.noLines, .categoryMissing(row: 0), .amountUnreadable(row: 0),
                      .amountOutOfRange(row: 0)].map(InvoiceReview.text)
        for code in ["INVOICE_NOT_RECOGNISED", "INVOICE_SCAN_INPUT_AMBIGUOUS", "INVOICE_NO_USABLE_LINES",
                     "INVOICE_SCAN_MEDIA_UNSUPPORTED", "INVOICE_SCAN_TOO_LARGE", "INVOICE_SCAN_UNAVAILABLE", "FILE_NOT_FOUND",
                     "COST_ENTRY_INVOICE_FILE_NOT_FOUND", "COST_ENTRY_INVOICE_UPLOAD_INCOMPLETE",
                     "COST_ENTRY_INVOICE_FILE_DELETED"] {
            sentences.append(UserMessage.bulgarian[code] ?? "missing \(code)")
        }
        for sentence in sentences {
            XCTAssertTrue(UserMessage.isBulgarianSentence(sentence), sentence)
        }
        let truncated = InvoiceReview.text(InvoiceWarning(code: "INVOICE_LINES_TRUNCATED",
                                                          params: ["found": 40, "proposed": 25]))
        XCTAssertTrue(truncated.contains("40") && truncated.contains("25"), truncated)
        XCTAssertTrue(InvoiceReview.text(InvoiceWarning(code: "INVOICE_LINE_FOREIGN_CURRENCY", params: ["count": 1]))
            .hasPrefix("1 ред е"))
        // The two 422s say different things: retake the photo, or type it.
        XCTAssertNotEqual(UserMessage.bulgarian["INVOICE_NOT_RECOGNISED"], UserMessage.bulgarian["INVOICE_NO_USABLE_LINES"])
    }

    /// The «Документи» path sends an id and no file part.
    func testAFieldsOnlyBodyHasNoFilePart() {
        let body = String(decoding: APIClient.multipartFieldsBody(boundary: "B", fields: ["documentId": "doc_1"]),
                          as: UTF8.self)
        XCTAssertEqual(body, "--B\r\nContent-Disposition: form-data; name=\"documentId\"\r\n\r\ndoc_1\r\n--B--\r\n")
        XCTAssertFalse(body.contains("filename="))
    }

    /// A typed line is unchanged: no invoice, no key, the same idempotency
    /// key it always minted.
    func testATypedLineCarriesNoInvoice() throws {
        let typed = CreateCostEntry(category: .fuel, amount: 10, currency: "EUR", incurredOn: "2026-10-31",
                                    supplier: nil, description: nil)
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as? [String: Any]
        XCTAssertNil(keys?["invoiceFileId"])
        XCTAssertTrue(CostsAPI.invoiceScanPath.hasSuffix("/grain/costs/invoice-scan"))
    }
}
