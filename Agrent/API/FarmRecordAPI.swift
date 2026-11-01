import Foundation

/// The farm's documents as PDFs, and what they share: the file, the folder
/// it is kept in, the empty-period answer.
///
/// «Дневник (PDF)» on the Дневник page is «ДНЕВНИК НА СТОПАНСТВОТО» for one
/// campaign (#436; agri-saas `POST /reports/campaign-diary`, owner
/// 2026-10-25). It covers the whole farm and every recorded activity, in the
/// owner's own template. It REPLACED the БАБХ ДНЕВНИК for a block and a
/// period (`POST /locations/{id}/farm-record`), which the phone no longer
/// asks for. The БАБХ register stays per treatment
/// (`TreatmentAPI.documentPath`). The server reads under `assertCanRead`, so
/// this POST writes nothing.
enum FarmRecordAPI {
    /// A campaign: 1 October to 30 September (owner, 2026-10-25),
    /// «Кампания 2024–2025» starting in the autumn of 2024.
    ///
    /// A pure function of a year, not a stored row. Production's only
    /// `Season` is the sample one, with other dates, so the phone offers
    /// campaigns it works out itself, and the server derives the same window
    /// from the parameter.
    struct Campaign: Hashable, Sendable, Identifiable {
        let startYear: Int
        var id: Int { startYear }

        /// `2024-2025`, the route's `campaign`.
        var parameter: String { "\(startYear)-\(startYear + 1)" }
        var label: String { "Кампания \(startYear)–\(startYear + 1)" }

        /// The campaign a day is in, by the farm's calendar: from October
        /// it is the one starting that autumn.
        static func containing(_ day: Date, calendar: Calendar = FarmRecordAPI.farmCalendar) -> Campaign {
            let parts = calendar.dateComponents([.year, .month], from: day)
            let year = parts.year ?? 2026
            return Campaign(startYear: (parts.month ?? 1) >= 10 ? year : year - 1)
        }

        /// The current campaign first, then the four before it: a farm's
        /// paperwork reaches back a few years, and the server answers any.
        static func recent(now: Date = Date(), calendar: Calendar = FarmRecordAPI.farmCalendar,
                           count: Int = 5) -> [Campaign] {
            let current = containing(now, calendar: calendar).startYear
            return (0..<count).map { Campaign(startYear: current - $0) }
        }
    }

    /// The farm's day is Bulgaria's, whatever zone the phone is set to:
    /// the server bounds a campaign in the farm's own timezone.
    static let farmCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia") ?? .current
        return calendar
    }()

    static func campaignPath(_ campaign: Campaign) -> String {
        "\(FarmPath.root)/reports/campaign-diary?campaign=\(campaign.parameter)"
    }

    /// The route reads only `campaign`; a POST still carries a body.
    private struct NoBody: Encodable {}

    static func fallbackName(_ campaign: Campaign) -> String {
        "dnevnik-na-stopanstvoto-\(campaign.parameter).pdf"
    }

    static func fileName(_ served: String?, fallback: String) -> String {
        let name = served ?? fallback
        return name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
    }

    /// `%PDF`, the first four bytes of every PDF. A 200 that is not one — a
    /// proxy's page, or JSON from a body that asked to file it — would write
    /// a `.pdf` Quick Look cannot open, so it is refused here instead.
    static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF".utf8))
    }

    /// A block with nothing recorded in the period (owner, 2026-10-22,
    /// confirmed to backend 1 on 2026-10-23; agri-saas #2183): the server
    /// gives no document, and the person is told so. Its OWN code, because a
    /// bare 404 also means "no such block" and "not this farm", and this is
    /// the one 404 that says nothing is wrong. An untreated block in a period
    /// is ordinary, so it is the one met most.
    static let emptyPeriodCode = "REGISTER_EMPTY_FOR_PERIOD"
    static let emptyPeriodText = "Няма записи за този период."
    /// The campaign diary's own: nothing was recorded in the campaign, or
    /// only work not yet finished. Not a fault (agri-saas's 404 says so).
    static let emptyCampaignText = "Няма записи за тази кампания."

    static func isEmptyPeriod(_ error: Error) -> Bool {
        if case APIClient.APIError.http(404, emptyPeriodCode?, _, _, _) = error { return true }
        return false
    }

    enum Failure: LocalizedError, Equatable {
        case notAPDF

        var errorDescription: String? {
            switch self {
            case .notAPDF: "Сървърът не върна PDF документ. Опитайте отново."
            }
        }
    }

    /// Up to a minute or more to build: a campaign's rows are uncapped by
    /// design, so the document session waits, and the sheet shows a spinner.
    static func generate(_ campaign: Campaign) async throws -> URL {
        let (data, served) = try await APIClient.shared.postForDocument(campaignPath(campaign), body: NoBody())
        UsageEvents.note(.farmDiaryDownloaded)
        return try keep(data, named: fileName(served, fallback: fallbackName(campaign)))
    }

    static func keep(_ data: Data, named name: String) throws -> URL {
        guard isPDF(data) else { throw Failure.notAPDF }
        removeGenerated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
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
