import Foundation

/// What a «Документи» row says, built from values so it can be tested
/// without a rendering pass, and spoken from the same parts it shows.
struct DocumentRowText: Equatable {
    /// The name, or «Изтрит документ» for one deleted by hand, whose name
    /// the server cleared (owner, 2026-10-30).
    let title: String
    /// Type, size and who uploaded it when: «PDF · 1,2 МБ · Иван, 30 октомври».
    let details: [String]
    /// Where the document stands: «Изтича на …», «Пази се без срок», or how
    /// it went. Never nil.
    let status: String
    /// The Drive copy, while the document is still on Agrent. Nil with sync off.
    let drive: String?
    /// The Drive copy failed: an admin gets «Опитай пак».
    let driveFailed: Bool

    init(_ document: FarmDocument, now: Date = Date()) {
        title = document.name ?? "Изтрит документ"
        let uploaded = document.uploadedAt.map { BgDate.rowDay($0, now: now) }
        details = [
            DocumentKind(contentType: document.contentType).label,
            document.sizeBytes.map { DocumentSize.text(Int64($0)) },
            [document.uploadedBy?.displayName, uploaded].compactMap { $0 }.joined(separator: ", ").recorded,
        ].compactMap { $0 }

        let purgedDay = document.purgedAt.map { BgDate.rowDay($0, now: now) }
        switch (document.isPurged, document.purgeReason) {
        case (true, .deleted?):
            status = ["Изтрит", purgedDay.map { "на \($0)" }, document.purgedBy?.displayName.map { "от \($0)" }]
                .compactMap { $0 }.joined(separator: " ")
        case (true, .expired?) where document.driveState == .copied:
            status = "Само в Google Drive"
        case (true, .expired?):
            status = ["Изтекъл срок", purgedDay.map { "на \($0)" }].compactMap { $0 }.joined(separator: " ")
        case (true, _):
            status = ["Изтрит", purgedDay.map { "на \($0)" }].compactMap { $0 }.joined(separator: " ")
        case (false, _):
            // No date is «Без срок», the one period without one.
            if let raw = document.expiresOn {
                status = BgDate.parseISODay(raw).map { "Изтича на \(BgDate.rowDay($0, now: now))" }
                    ?? "Срокът не може да бъде прочетен"
            } else {
                status = "Пази се без срок"
            }
        }

        if document.isPurged {
            drive = nil
            driveFailed = false
        } else {
            switch document.driveState {
            case .copied: drive = "Копие в Google Drive"
            case .pending: drive = "Копира се в Google Drive"
            case .failed: drive = "Копирането в Google Drive не успя"
            case .off, .unknown: drive = nil
            }
            driveFailed = document.driveState == .failed
        }
    }

    /// The row, for VoiceOver, from the values.
    var spoken: String { A11y.sentence([title] + details + [status, drive]) }
}

/// A document's kind, from its type, in words a farmer uses.
enum DocumentKind: Equatable {
    case pdf, image, word, sheet, text, other

    init(contentType: String?) {
        let type = (contentType ?? "").lowercased()
        if type == "application/pdf" { self = .pdf }
        else if type.hasPrefix("image/") { self = .image }
        else if type.contains("wordprocessing") || type == "application/msword" { self = .word }
        else if type.contains("spreadsheet") || type == "application/vnd.ms-excel" || type == "text/csv" { self = .sheet }
        else if type.hasPrefix("text/") { self = .text }
        else { self = .other }
    }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .image: "Снимка"
        case .word: "Word"
        case .sheet: "Таблица"
        case .text: "Текст"
        case .other: "Файл"
        }
    }

    var icon: String {
        switch self {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .word: "doc.text"
        case .sheet: "tablecells"
        case .text: "doc.plaintext"
        case .other: "doc"
        }
    }
}

/// A size in bytes, as Bulgarian writes it: «1,2 МБ». BINARY units (1 КБ =
/// 1024 Б): the farm's ceiling is 2 GiB on the server (agri-saas #2534), and
/// in decimal units it would read «2,1 ГБ» beside a limit everybody calls
/// 2 GB. One unit system for the limit and the files under it.
enum DocumentSize {
    static func text(_ bytes: Int64) -> String {
        let units: [(Double, String)] = [(1_073_741_824, "ГБ"), (1_048_576, "МБ"), (1024, "КБ")]
        let value = Double(bytes)
        for (size, unit) in units where value >= size {
            let scaled = value / size
            // One decimal under ten, and none when it is zero: «1,2 МБ»,
            // «2 ГБ», «340 КБ».
            let number = scaled.formatted(.number.precision(.fractionLength(scaled < 10 ? 0...1 : 0...0))
                .locale(BgDate.locale))
            return "\(number) \(unit)"
        }
        return "\(bytes) Б"
    }

    /// «Използвани 120 МБ от 2 ГБ».
    static func usage(used: Int64, limit: Int64) -> String {
        "Използвани \(text(used)) от \(text(limit))"
    }
}

extension DocumentRetention {
    /// The day a document uploaded now would leave Agrent, for the warning
    /// before an upload. The server's `expiresOn` is the record (counted in
    /// the farm's zone); this is the phone's same count, said ahead of time.
    func expiry(from now: Date, calendar: Calendar = .current) -> Date? {
        let months: Int
        switch self {
        case .months3: months = 3
        case .months6: months = 6
        case .year1: months = 12
        case .years2: months = 24
        case .years5: months = 60
        case .none, .unknown: return nil
        }
        // `Calendar` clamps to the month's end: 31 August + 6 months is
        // 28 or 29 February, never 3 March.
        return calendar.date(byAdding: .month, value: months, to: calendar.startOfDay(for: now))
    }
}
