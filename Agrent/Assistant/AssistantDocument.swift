import Foundation

/// A ДНЕВНИК PDF the assistant OFFERS (#661, agri-saas#3158; owner
/// 2026-11-17: "offer the download"). Asked in the chat for the journal, the
/// answer carries a button; a tap makes the PDF through the document's own
/// route, under this person's session, and opens it to read or share. The
/// assistant writes and generates nothing — recording stays the filled
/// «Нов запис» (`AssistantProposal`).
///
/// Three documents, each a route the phone already reads or the server
/// already serves:
/// - «Дневник на стопанството» for a campaign (`FarmRecordAPI.generate`);
/// - the БАБХ ДНЕВНИК for one block over a period
///   (`POST /locations/{id}/farm-record`), which the Дневник page no longer
///   offers since the campaign diary replaced it, but which stays the
///   register for a block (owner, 2026-11-17: all three);
/// - one recorded treatment's (`TreatmentAPI.document(forTreatment:)`).
///
/// Read leniently: an offer this build does not know, or one missing what
/// its route needs, is no button — the answer still shows.
struct AssistantDocument: Decodable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case campaign(FarmRecordAPI.Campaign)
        case block(locationID: String, from: String, to: String)
        case treatment(handle: String)
    }

    /// Bulgarian, built by the server from what it read.
    let label: String
    let target: Target

    private enum CodingKeys: String, CodingKey {
        case kind, label, campaign, locationId, from, to, treatmentGroupId
    }

    init(label: String, target: Target) {
        self.label = label
        self.target = target
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: c, debugDescription: "empty label")
        }
        switch kind {
        case "farm-campaign":
            let raw = try c.decode(String.self, forKey: .campaign)
            guard let campaign = Self.campaign(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .campaign, in: c, debugDescription: raw)
            }
            target = .campaign(campaign)
        case "block-register":
            let id = try c.decode(String.self, forKey: .locationId)
            let from = try c.decode(String.self, forKey: .from)
            let to = try c.decode(String.self, forKey: .to)
            guard !id.isEmpty, Self.isDay(from), Self.isDay(to) else {
                throw DecodingError.dataCorruptedError(forKey: .from, in: c, debugDescription: "block-register")
            }
            target = .block(locationID: id, from: from, to: to)
        case "treatment":
            let handle = try c.decode(String.self, forKey: .treatmentGroupId)
            guard !handle.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .treatmentGroupId, in: c, debugDescription: "empty")
            }
            target = .treatment(handle: handle)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(kind)")
        }
    }

    /// `2025-2026` → the campaign starting in the autumn of 2025; the two
    /// years must follow each other, as the server requires.
    static func campaign(_ raw: String) -> FarmRecordAPI.Campaign? {
        let parts = raw.split(separator: "-")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
              parts[0].count == 4, end == start + 1 else { return nil }
        return FarmRecordAPI.Campaign(startYear: start)
    }

    private static func isDay(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

/// Making the offered document: one call per target, each the route's own.
enum AssistantDocumentAPI {
    /// The block register's route, with the block in the PATH (a URL's query
    /// is written to the device log; an id in the path names nobody).
    static func blockRegisterPath(_ locationID: String) -> String {
        "\(FarmPath.root)/locations/\(URLEscape.segment(locationID))/farm-record"
    }

    private struct Period: Encodable {
        let from: String
        let to: String
    }

    /// The PDF, kept where the Дневник keeps its documents
    /// (`FarmRecordAPI.keep`), so it is removed the same way.
    static func make(_ document: AssistantDocument) async throws -> URL {
        switch document.target {
        case .campaign(let campaign):
            return try await FarmRecordAPI.generate(campaign)
        case .treatment(let handle):
            return try await TreatmentAPI.document(forTreatment: handle)
        case .block(let id, let from, let to):
            let (data, served) = try await APIClient.shared.postForDocument(
                blockRegisterPath(id), body: Period(from: from, to: to))
            UsageEvents.note(.diaryPDFDownloaded)
            return try FarmRecordAPI.keep(data, named: FarmRecordAPI.fileName(served, fallback: "dnevnik-\(from)_\(to).pdf"))
        }
    }

    /// What to say when the document cannot be made: the empty period in the
    /// Дневник's own words, otherwise the app's usual sentence.
    static func failure(_ error: Error, for document: AssistantDocument) -> String {
        if FarmRecordAPI.isEmptyPeriod(error) {
            if case .campaign = document.target { return FarmRecordAPI.emptyCampaignText }
            return FarmRecordAPI.emptyPeriodText
        }
        if case .treatment = document.target, TreatmentAPI.isNothingRecorded(error) {
            return FarmRecordAPI.emptyPeriodText
        }
        if let refused = error as? FarmRecordAPI.Failure, let text = refused.errorDescription { return text }
        return UserMessage.text(for: error)
    }
}
