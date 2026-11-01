import Foundation

/// A change the assistant PREPARED (#483 phase 2, agri-saas #2636): asked to
/// record something, it answers with a draft, and the phone opens the usual
/// «Нов запис» filled with it for the person to check, complete and send
/// (owner, 2026-10-31: "it opens the usual form, filled"). Nothing is stored
/// before that; the assistant never posts.
///
/// ── Two kinds, each a form the phone has ──
///
/// `treatment` is `POST /journal/treatments`' human-readable fields; `activity`
/// is `POST /journal/activities`'. Never an id: the parcels, the product
/// from the catalogue and the dose's unit are the person's, picked in the
/// form where they can see them. A kind this build does not know is shown
/// as text only, never opened. The proposal is `{kind, draft}` and nothing
/// else: a draft the server refuses arrives as no proposal at all.
struct AssistantProposal: Decodable, Equatable, Sendable {
    let kind: String
    let draft: Draft?

    enum Draft: Equatable, Sendable {
        case treatment(TreatmentFields)
        case activity(ActivityFields)
    }

    struct TreatmentFields: Decodable, Equatable, Sendable {
        let kind: String?
        let occurredOn: String?
        let productName: String?
        let fertilizerName: String?
        let doseValue: WireDecimal?
        let targetNote: String?
        let phenophase: String?
        let pppRegistrationNo: String?
        let quarantinePeriodDays: Int?
        let applicationTechnique: String?
    }

    struct ActivityFields: Decodable, Equatable, Sendable {
        let kind: String?
        let occurredOn: String?
        let harvestKg: WireDecimal?
    }

    private enum CodingKeys: String, CodingKey { case kind, draft }

    init(kind: String, draft: Draft?) {
        self.kind = kind
        self.draft = draft
    }

    /// A draft that does not decode costs the button, never the answer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "treatment":
            draft = (try? c.decode(TreatmentFields.self, forKey: .draft)).map(Draft.treatment)
        case "activity":
            draft = (try? c.decode(ActivityFields.self, forKey: .draft)).map(Draft.activity)
        default:
            draft = nil
        }
    }

    /// «Нов запис» filled from the draft, or nil when there is nothing this
    /// phone can open: an unknown kind or an unreadable draft.
    func entry(today: Date = Date()) -> TreatmentDraft? {
        guard let draft else { return nil }
        var entry = TreatmentDraft(date: today)
        switch draft {
        case .treatment(let fields):
            entry.kind = fields.kind.flatMap { TreatmentDraft.Kind(rawValue: $0) } ?? .spray
            entry.activity = nil
            entry.date = Self.day(fields.occurredOn, today: today)
            entry.productText = fields.productName ?? fields.fertilizerName ?? ""
            entry.doseText = fields.doseValue.map { NewListingView.fieldText($0.value) } ?? ""
            entry.pestText = fields.targetNote ?? ""
            entry.phenophaseText = fields.phenophase ?? ""
            entry.registrationText = fields.pppRegistrationNo ?? ""
            entry.quarantineText = fields.quarantinePeriodDays.map(String.init) ?? ""
            if let technique = fields.applicationTechnique.flatMap({ ApplicationTechnique(rawValue: $0.lowercased()) }) {
                entry.technique = technique
            }
        case .activity(let fields):
            guard let work = fields.kind.flatMap(ActivityKind.init(rawValue:)) else { return nil }
            entry.activity = work
            entry.date = Self.day(fields.occurredOn, today: today)
            entry.harvestText = fields.harvestKg.map { NewListingView.fieldText($0.value) } ?? ""
        }
        return entry
    }

    /// The draft's day, never in the future: the form records done work, and
    /// its date picker stops at today.
    private static func day(_ text: String?, today: Date) -> Date {
        guard let text, let day = BgDate.parseISODay(text) else { return today }
        return min(day, today)
    }
}
