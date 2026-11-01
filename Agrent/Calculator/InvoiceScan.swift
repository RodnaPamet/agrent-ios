import Foundation

/// An invoice read into expenses (#482, owner 2026-10-31): a scan from
/// «Нов разход», or a document already in «Документи», sent to
/// `POST /grain/costs/invoice-scan`, which reads it and answers with the
/// lines it found. It SAVES NOTHING: the owner's rule is "fill the form, you
/// tap «Запиши»", and the save is the ordinary sheet (`POST /grain/costs/batch`).
///
/// ── What comes back ──
///
/// Lines in the batch's own shape, so a line the person leaves as read posts
/// as it came; the stored invoice's id on every one; at most 25 (the batch's
/// bound), with a warning saying how many more there were rather than a
/// silent cut. Lev is already euros at 1,95583, the original in the line's
/// description.
struct InvoiceScan: Decodable, Equatable, Sendable {
    let invoiceFileId: String
    let lines: [InvoiceLine]
    let warnings: [InvoiceWarning]

    private enum CodingKeys: String, CodingKey { case invoiceFileId, lines, warnings }

    init(invoiceFileId: String, lines: [InvoiceLine], warnings: [InvoiceWarning]) {
        self.invoiceFileId = invoiceFileId
        self.lines = lines
        self.warnings = warnings
    }

    /// A line that does not decode is dropped, and said: one odd line costs
    /// itself, never the invoice.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invoiceFileId = try c.decode(String.self, forKey: .invoiceFileId)
        var found: [InvoiceLine] = []
        var dropped = 0
        if var list = try? c.nestedUnkeyedContainer(forKey: .lines) {
            while !list.isAtEnd {
                if let line = try? list.decode(InvoiceLine.self) {
                    found.append(line)
                } else {
                    dropped += 1
                    _ = try? list.decode(Skipped.self)
                }
            }
        }
        lines = found
        var warnings = (try? c.decodeIfPresent([InvoiceWarning].self, forKey: .warnings)) ?? []
        if dropped > 0 { warnings.append(InvoiceWarning(code: InvoiceWarning.unreadLines, params: ["count": dropped])) }
        self.warnings = warnings
    }

    private struct Skipped: Decodable {}
}

/// One proposed expense: the batch line's fields this phone shows and
/// sends. Attribution comes back only where the reader was sure: `CROP` with
/// its crop, or nothing, which the review list offers as «Общи».
struct InvoiceLine: Decodable, Equatable, Sendable {
    let category: CostCategory
    let amount: WireDecimal
    let currency: String?
    let incurredOn: String?
    let supplier: String?
    let description: String?
    let commodityCanonical: String?
    let allocationBasis: String?
}

/// Something about the invoice as a whole: a CODE and its numbers, never a
/// sentence — the server sends no prose here, so the reader's language is
/// the phone's to give (backend 1, 2026-10-31). `params` holds counts only,
/// never anything read off the document.
struct InvoiceWarning: Decodable, Equatable, Sendable {
    let code: String
    let params: [String: Int]

    private enum CodingKeys: String, CodingKey { case code, params }

    init(code: String, params: [String: Int] = [:]) {
        self.code = code
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        params = (try? c.decodeIfPresent([String: Int].self, forKey: .params)) ?? [:]
    }

    /// The phone's own: lines in the answer it could not decode.
    static let unreadLines = "PHONE_UNREAD_LINES"
}

enum InvoiceScanAPI {
    static var path: String { CostsAPI.invoiceScanPath }

    /// A scan or a photo, sent as bytes. Not retried: reading an invoice
    /// spends the farm's AI budget, and a second read is the person's choice.
    static func scan(_ file: Data, fileName: String, mimeType: String) async throws -> InvoiceScan {
        let data = try await APIClient.shared.postMultipart(path, file: file, fileName: fileName, mimeType: mimeType)
        return try await APIClient.shared.decode(data, as: InvoiceScan.self)
    }

    /// A document already in «Документи», by its id: the server reads the
    /// bytes it holds, so nothing is uploaded twice.
    static func scan(documentId: String) async throws -> InvoiceScan {
        let data = try await APIClient.shared.postMultipart(path, fields: ["documentId": documentId])
        return try await APIClient.shared.decode(data, as: InvoiceScan.self)
    }
}
