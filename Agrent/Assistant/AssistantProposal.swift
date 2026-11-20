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
        case cost(CostFields)
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
        /// The field the server resolved from the chat (agri-saas#3162):
        /// parcels the person can read, all one crop.
        let chosenParcels: [ChosenParcel]?
        /// The dose unit as said («л/дка»), matched in the form.
        let doseUnitLabel: String?

        private enum CodingKeys: String, CodingKey {
            case kind, occurredOn, productName, fertilizerName, doseValue, targetNote, phenophase,
                 pppRegistrationNo, quarantinePeriodDays, applicationTechnique, chosenParcels, doseUnitLabel
        }

        init(kind: String? = nil, occurredOn: String? = nil, productName: String? = nil, fertilizerName: String? = nil,
             doseValue: WireDecimal? = nil, targetNote: String? = nil, phenophase: String? = nil,
             pppRegistrationNo: String? = nil, quarantinePeriodDays: Int? = nil, applicationTechnique: String? = nil,
             chosenParcels: [ChosenParcel]? = nil, doseUnitLabel: String? = nil) {
            self.kind = kind
            self.occurredOn = occurredOn
            self.productName = productName
            self.fertilizerName = fertilizerName
            self.doseValue = doseValue
            self.targetNote = targetNote
            self.phenophase = phenophase
            self.pppRegistrationNo = pppRegistrationNo
            self.quarantinePeriodDays = quarantinePeriodDays
            self.applicationTechnique = applicationTechnique
            self.chosenParcels = chosenParcels
            self.doseUnitLabel = doseUnitLabel
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            occurredOn = try c.decodeIfPresent(String.self, forKey: .occurredOn)
            productName = try c.decodeIfPresent(String.self, forKey: .productName)
            fertilizerName = try c.decodeIfPresent(String.self, forKey: .fertilizerName)
            doseValue = try c.decodeIfPresent(WireDecimal.self, forKey: .doseValue)
            targetNote = try c.decodeIfPresent(String.self, forKey: .targetNote)
            phenophase = try c.decodeIfPresent(String.self, forKey: .phenophase)
            pppRegistrationNo = try c.decodeIfPresent(String.self, forKey: .pppRegistrationNo)
            quarantinePeriodDays = try c.decodeIfPresent(Int.self, forKey: .quarantinePeriodDays)
            applicationTechnique = try c.decodeIfPresent(String.self, forKey: .applicationTechnique)
            // The two new fields cost themselves, never the draft: an older
            // or odd shape leaves the person to pick, as before.
            chosenParcels = (try? c.decodeIfPresent([ChosenParcel].self, forKey: .chosenParcels)) ?? nil
            doseUnitLabel = (try? c.decodeIfPresent(String.self, forKey: .doseUnitLabel)) ?? nil
        }
    }

    struct ChosenParcel: Decodable, Equatable, Sendable {
        let id: String
        let label: String
        let crop: String?
    }

    struct ActivityFields: Decodable, Equatable, Sendable {
        let kind: String?
        let occurredOn: String?
        let harvestKg: WireDecimal?
    }

    /// An expense (agri-saas propose `cost`, owner 2026-11-20): the fields of
    /// `POST /grain/costs` a conversation can state. The crop arrives already
    /// canonical («wheat»); no id, no currency — the review books in euros,
    /// as every line from the phone does.
    struct CostFields: Decodable, Equatable, Sendable {
        let category: String?
        let amount: WireDecimal?
        let incurredOn: String?
        let supplier: String?
        let description: String?
        /// The crop's canonical slug, the wire's `commodityCanonical`. Named
        /// `crop` here because it is data, never shown as is: the review
        /// renders it through `CommodityName`.
        let crop: String?

        private enum CodingKeys: String, CodingKey {
            case category, amount, incurredOn, supplier, description
            case crop = "commodityCanonical"
        }

        init(category: String? = nil, amount: WireDecimal? = nil, incurredOn: String? = nil,
             supplier: String? = nil, description: String? = nil, crop: String? = nil) {
            self.category = category
            self.amount = amount
            self.incurredOn = incurredOn
            self.supplier = supplier
            self.description = description
            self.crop = crop
        }
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
        case "cost":
            draft = (try? c.decode(CostFields.self, forKey: .draft)).map(Draft.cost)
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
            // The field and unit from the chat (#663): ticked and chosen in
            // the form, for the person to check. One crop per record.
            let parcels = fields.chosenParcels ?? []
            entry.saidParcels = Set(parcels.map(\.id))
            entry.saidCrop = parcels.compactMap(\.crop).first
            entry.saidUnit = fields.doseUnitLabel
        case .activity(let fields):
            guard let work = fields.kind.flatMap(ActivityKind.init(rawValue:)) else { return nil }
            entry.activity = work
            entry.date = Self.day(fields.occurredOn, today: today)
            entry.harvestText = fields.harvestKg.map { NewListingView.fieldText($0.value) } ?? ""
        case .cost:
            // An expense is not a journal record: it opens `costReview`.
            return nil
        }
        return entry
    }

    /// An expense draft as the review the person checks before «Запиши»,
    /// or nil when this proposal is not one.
    func costReview(crops: [CropChoice] = [], today: Date = Date()) -> InvoiceReview? {
        guard case .cost(let fields)? = draft else { return nil }
        return InvoiceReview(proposed: fields, crops: crops, today: today)
    }

    /// The draft's day, never in the future: the form records done work, and
    /// its date picker stops at today.
    private static func day(_ text: String?, today: Date) -> Date {
        guard let text, let day = BgDate.parseISODay(text) else { return today }
        return min(day, today)
    }
}
