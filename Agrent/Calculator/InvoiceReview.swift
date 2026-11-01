import Foundation

/// «От фактура» (#482): the lines an invoice was read into, as the person
/// checks and corrects them before «Запиши». Pure, so its rules are tests and
/// the screen only draws them.
///
/// ── Totals, not rates ──
///
/// An invoice says what was paid, so every line here is a TOTAL. «Нов
/// разход»'s «Култура» sheet takes rates per decare (owner, 2026-10-09), so
/// invoice lines are not put into it; a line is booked either on one crop
/// (`CROP`, the total summed onto that crop — agri-saas #2543's answer: a
/// total with no rate is valid) or over the whole farm by area («Общи»,
/// `HOLDING`, exactly as the «Общи» sheet books its lines).
struct InvoiceReview: Equatable {
    enum Attribution: Hashable {
        /// The whole farm, by area: the «Общи» sheet's `HOLDING`.
        case farm
        /// One crop, by its canonical name.
        case crop(String)
    }

    struct Row: Equatable, Identifiable {
        var id = UUID()
        var category: CostCategory
        var amountText: String
        var incurredOn: Date
        var supplier: String
        var note: String
        var attribution: Attribution
    }

    let invoiceFileId: String
    var rows: [Row]
    let warnings: [InvoiceWarning]

    /// The batch's bound (agri-saas #1604): one transaction.
    static let maxLines = CropSheet.maxLines

    /// The read lines as rows. A crop the farm has no land for this season
    /// is not offered, so such a line starts as «Общи» for the person to
    /// decide; an unreadable date starts as today, for the same reason. With
    /// no crops known yet (opened from «Документи», which reads them after),
    /// the reader's crop is kept as it came.
    init(_ scan: InvoiceScan, crops: [CropChoice], today: Date = Date()) {
        invoiceFileId = scan.invoiceFileId
        warnings = scan.warnings
        let offered: Set<String>? = crops.isEmpty ? nil : Set(crops.map(\.id))
        rows = scan.lines.prefix(Self.maxLines).map { line in
            let crop = line.allocationBasis == CostAllocationBasis.crop.rawValue
                ? line.commodityCanonical.flatMap { offered == nil || offered!.contains($0) ? $0 : nil } : nil
            return Row(
                category: line.category,
                amountText: NewListingView.fieldText(line.amount.value),
                incurredOn: BgDate.parseInstantOrDay(line.incurredOn) ?? today,
                supplier: line.supplier ?? "",
                note: line.description ?? "",
                attribution: crop.map(Attribution.crop) ?? .farm
            )
        }
    }

    enum Problem: Equatable {
        case noLines
        case categoryMissing(row: Int)
        case amountUnreadable(row: Int)
        case amountOutOfRange(row: Int)
    }

    /// The amount as typed: a comma or a full stop, spaces ignored.
    static func amount(_ text: String) -> Decimal? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: WireDecimal.wireLocale)
    }

    /// What stops «Запиши», first row first.
    var problems: [Problem] {
        guard !rows.isEmpty else { return [.noLines] }
        var found: [Problem] = []
        for (index, row) in rows.enumerated() {
            if row.category == .unknown { found.append(.categoryMissing(row: index)) }
            guard let amount = Self.amount(row.amountText) else {
                found.append(.amountUnreadable(row: index))
                continue
            }
            if amount <= 0 || amount > CreateCostEntry.maxAmount { found.append(.amountOutOfRange(row: index)) }
        }
        return found
    }

    /// The sheet as the batch takes it: every line the invoice's, in euros,
    /// on one crop or over the whole farm, and nothing else of attribution —
    /// `CROP` refuses a place, `HOLDING` refuses a crop (agri-saas #2543).
    var sheet: CostsAPI.Sheet? {
        guard problems.isEmpty else { return nil }
        let lines: [CreateCostEntry] = rows.compactMap { row in
            guard let amount = Self.amount(row.amountText) else { return nil }
            var line = CreateCostEntry(
                category: row.category, amount: amount, currency: "EUR",
                incurredOn: BgDate.isoDay(row.incurredOn),
                supplier: row.supplier.recorded, description: row.note.recorded)
            switch row.attribution {
            case .farm:
                line.allocationBasis = .holding
            case .crop(let commodity):
                line.allocationBasis = .crop
                line.commodityCanonical = commodity
            }
            line.invoiceFileId = invoiceFileId
            return line
        }
        return CostsAPI.Sheet(lines: lines)
    }

    /// A row's words for its own problem, or nil.
    static func text(_ problem: Problem) -> String {
        switch problem {
        case .noLines: "Няма редове за записване."
        case .categoryMissing: "Изберете вид разход."
        case .amountUnreadable: "Сумата не е разчетена."
        case .amountOutOfRange: "Сумата трябва да е по-голяма от нула."
        }
    }

    /// The invoice's warnings, in Bulgarian: the server sends a code and
    /// counts (agri-saas invoice-scan), the words are the phone's.
    static func text(_ warning: InvoiceWarning) -> String {
        let count = warning.params["count"]
        switch warning.code {
        case "INVOICE_LINES_TRUNCATED":
            // The one that matters most: a 40-line invoice proposed as 25
            // would otherwise look complete and total wrong.
            let found = warning.params["found"]
            let shown = warning.params["proposed"] ?? maxLines
            if let found {
                return "Фактурата има \(found) реда; показани са първите \(shown). Останалите въведете отделно."
            }
            return "Показани са първите \(shown) реда. Останалите въведете отделно."
        case "INVOICE_LINES_UNREADABLE", InvoiceWarning.unreadLines:
            if let count {
                return "\(Plural.bg(count, "ред", "реда")) от фактурата не бяха разчетени и не са тук. Въведете ги отделно."
            }
            return "Някои редове от фактурата не бяха разчетени и не са тук. Въведете ги отделно."
        case "INVOICE_LINE_FOREIGN_CURRENCY":
            if let count {
                return "\(Plural.bg(count, "ред е", "реда са")) в чужда валута и не са тук. Въведете ги отделно в евро."
            }
            return "Редове в чужда валута не са тук. Въведете ги отделно в евро."
        case "INVOICE_LINE_AMOUNT_UNREADABLE":
            if let count {
                return "Сумата на \(Plural.bg(count, "ред", "реда")) не беше разчетена и те не са тук. Въведете ги отделно."
            }
            return "Някои суми не бяха разчетени и редовете им не са тук. Въведете ги отделно."
        default:
            return "Проверете редовете спрямо фактурата."
        }
    }

    /// What «За» shows for a row: the crop by its Bulgarian name, or the
    /// whole farm.
    static func label(_ attribution: Attribution) -> String {
        switch attribution {
        case .farm: farmLabel
        case .crop(let commodity): CommodityName.canonical(commodity) ?? commodity
        }
    }

    static let farmLabel = "Общи (за цялото стопанство)"

    /// The sentence over the list: what to check before «Запиши».
    static let checkFirst = "Проверете всеки ред спрямо фактурата, преди да запишете."
}
