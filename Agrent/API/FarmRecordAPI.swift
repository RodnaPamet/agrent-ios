import Foundation

/// The БАБХ ДНЕВНИК as a PDF (#246) — agri-saas's
/// `POST /locations/{id}/farm-record`, the route the web's «Дневник (PDF)»
/// calls from a location and from a journal entry.
///
/// ONE 200, TWO MEDIA TYPES, chosen by `save` in the body: absent, it is the
/// PDF's bytes with `Content-Disposition: attachment`; `save: true` files it
/// in the farm's register instead and answers JSON. This app only ever asks
/// for the bytes, so `save` is never sent — filing is the web's. The server
/// reads under `assertCanRead`, so this POST writes nothing: it is a job with
/// a body, not a record, and none of the outward-write care applies.
enum FarmRecordAPI {
    static func path(_ locationID: String) -> String {
        "\(FarmPath.root)/locations/\(URLEscape.segment(locationID))/farm-record"
    }

    struct Request: Encodable, Equatable, Sendable {
        /// yyyy-mm-dd, the day in the device's zone — `BgDate.isoDay`, the
        /// write side every date-only field in this app goes through.
        let from: String
        let to: String
    }

    /// The period the web offers first: 1 January of this year to today.
    static func defaultPeriod(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        let january = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
        return (january, now)
    }

    /// The name the web falls back to when the server gives none.
    static func fallbackName(_ request: Request) -> String {
        "dnevnik-\(request.from)_\(request.to).pdf"
    }

    /// The name the file is written under: the server's, or the fallback —
    /// and always ending `.pdf`, because Quick Look reads the type off it.
    static func fileName(_ served: String?, for request: Request) -> String {
        let name = served ?? fallbackName(request)
        return name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
    }

    /// `%PDF`, the first four bytes of every PDF. A 200 that is not one — a
    /// proxy's page, or JSON from a body that asked to file it — would write
    /// a `.pdf` Quick Look cannot open, so it is refused here instead.
    static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF".utf8))
    }

    enum Failure: LocalizedError, Equatable {
        case notAPDF

        var errorDescription: String? {
            switch self {
            case .notAPDF: "Сървърът не върна PDF документ. Опитайте отново."
            }
        }
    }

    /// Generated, checked to BE a PDF, and written where Quick Look can open
    /// it. The ДНЕВНИК names the farm's producer, so it is written under
    /// complete protection, in a folder of its own that holds only the
    /// latest one — emptied before each, and removed when the sheet closes
    /// (`removeGenerated`). A copy the person shares or saves is theirs; this
    /// one is never the app's to keep.
    static func generate(locationID: String, from: Date, to: Date) async throws -> URL {
        let request = Request(from: BgDate.isoDay(from), to: BgDate.isoDay(to))
        let (data, served) = try await APIClient.shared.postForDocument(path(locationID), body: request)
        guard isPDF(data) else { throw Failure.notAPDF }
        removeGenerated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName(served, for: request))
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    /// The folder the ДНЕВНИК is written to — nothing else goes in it.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("farm-record", isDirectory: true)
    }

    /// Called when the sheet closes: on the PRESENTER's dismissal, not the
    /// sheet's `onDisappear`, which fires under Quick Look's full-screen
    /// preview — and would delete the document while it is being read.
    static func removeGenerated() {
        try? FileManager.default.removeItem(at: directory)
    }
}
