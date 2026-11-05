import Foundation

/// The superuser's «Промоции» console (#529, owner 2026-11-02): one catalogue
/// for every farm, kept from the phone. agri-saas #2727 (spec #2749).
///
/// Only on the platform farm, to its owner or admins, as the prices are
/// (`Farm.offersPlatformPrices`): the routes answer 404 everywhere else, so
/// that the console does not announce itself.
///
/// EVERY write here is outward-facing: a published offer reaches every
/// farm. Nothing is created, published or deleted from development, CI or
/// the screenshots; the owner makes the first real one. And nothing reaches
/// a farm without two deliberate acts: a draft is created, then published
/// (`PUT`), and a leaflet's read creates nothing at all.
enum AdminPromotionsAPI {
    private static var base: String { "\(FarmPath.root)/admin/promotions" }
    static var listPath: String { base }
    static func promotionPath(_ id: String) -> String { "\(base)/\(URLEscape.segment(id))" }
    static func imagePath(_ id: String) -> String { "\(promotionPath(id))/image" }
    static func leadsPath(_ id: String) -> String { "\(promotionPath(id))/leads" }
    static var leafletScanPath: String { "\(base)/leaflet-scan" }
    static var companiesPath: String { "\(FarmPath.root)/admin/companies" }
    static func companyPath(_ id: String) -> String { "\(companiesPath)/\(URLEscape.segment(id))" }

    enum Status: String, LenientDecodable, Sendable {
        case draft = "DRAFT", scheduled = "SCHEDULED", live = "LIVE", expired = "EXPIRED"
        case unknown = "__unknown__"

        static var unknownCase: Self { .unknown }

        /// The server's own reading of `publishedAt` and the window together,
        /// so the phone never decides which farms see it.
        var label: String {
            switch self {
            case .draft: "Чернова"
            case .scheduled: "Насрочена"
            case .live: "Активна"
            case .expired: "Изтекла"
            case .unknown: "—"
            }
        }
    }

    struct Promotion: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let companyId: String
        let companyName: String
        let title: String
        let body: String?
        let mediaUrl: String?
        let category: PromotionsAPI.Category
        let ctaUrl: String?
        /// The ЗЗР registration number when this advertises a plant
        /// protection product; nil when it does not.
        let pppRegistrationNo: String?
        /// Nil is a draft.
        let publishedAt: Date?
        /// Days. The admin route sends instants until its follow-up and day
        /// keys after (agreed 2026-11-05): read either way.
        let validFrom: Date?
        let validTo: Date?
        let status: Status
        /// Enquiries captured. Above 0 the offer can only be taken down,
        /// never deleted: a farm's enquiry is its record of having asked.
        let leadCount: Int

        private enum CodingKeys: String, CodingKey {
            case id, companyId, companyName, title, body, mediaUrl, category, ctaUrl, pppRegistrationNo
            case publishedAt, validFrom, validTo, status, leadCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            companyId = try c.decode(String.self, forKey: .companyId)
            companyName = try c.decode(String.self, forKey: .companyName)
            title = try c.decode(String.self, forKey: .title)
            body = (try? c.decodeIfPresent(String.self, forKey: .body))?.recorded
            mediaUrl = try? c.decodeIfPresent(String.self, forKey: .mediaUrl)
            category = (try? c.decodeIfPresent(PromotionsAPI.Category.self, forKey: .category)) ?? .other
            ctaUrl = (try? c.decodeIfPresent(String.self, forKey: .ctaUrl))?.recorded
            pppRegistrationNo = (try? c.decodeIfPresent(String.self, forKey: .pppRegistrationNo))?.recorded
            publishedAt = (try? c.decodeIfPresent(String.self, forKey: .publishedAt)).flatMap(BgDate.parseInstantOrDay)
            validFrom = (try? c.decodeIfPresent(String.self, forKey: .validFrom)).flatMap(BgDate.parseInstantOrDay)
            validTo = (try? c.decodeIfPresent(String.self, forKey: .validTo)).flatMap(BgDate.parseInstantOrDay)
            status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .unknown
            leadCount = (try? c.decodeIfPresent(Int.self, forKey: .leadCount)) ?? 0
        }

        var isPublished: Bool { publishedAt != nil }
    }

    struct Company: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        var name: String
        var eik: String?
        var websiteUrl: String?
        var contactName: String?
        var contactEmail: String?
        var contactPhone: String?
        var notes: String?
        let promotionCount: Int

        private enum CodingKeys: String, CodingKey {
            case id, name, eik, websiteUrl, contactName, contactEmail, contactPhone, notes, promotionCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            eik = (try? c.decodeIfPresent(String.self, forKey: .eik))?.recorded
            websiteUrl = (try? c.decodeIfPresent(String.self, forKey: .websiteUrl))?.recorded
            contactName = (try? c.decodeIfPresent(String.self, forKey: .contactName))?.recorded
            contactEmail = (try? c.decodeIfPresent(String.self, forKey: .contactEmail))?.recorded
            contactPhone = (try? c.decodeIfPresent(String.self, forKey: .contactPhone))?.recorded
            notes = (try? c.decodeIfPresent(String.self, forKey: .notes))?.recorded
            promotionCount = (try? c.decodeIfPresent(Int.self, forKey: .promotionCount)) ?? 0
        }
    }

    /// What a leaflet's read proposes, for the owner to check one by one.
    /// The price exactly as printed; nothing is created from it.
    struct LeafletScan: Decodable, Equatable, Sendable {
        let companyName: String?
        let offers: [Offer]
        /// Offers the server saw and could not read: said, not swallowed.
        let unreadableOfferCount: Int

        struct Offer: Decodable, Equatable, Sendable, Identifiable {
            let productName: String
            let priceText: String?
            let validityText: String?
            let note: String?
            var id: String { [productName, priceText ?? "", validityText ?? ""].joined(separator: "|") }
        }
    }

    /// One farm's enquiry about a promotion («Кой е питал», agri-saas #2760),
    /// for the owner to pass to the supplier. Personal data: read live,
    /// never cached on disk.
    struct Lead: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        /// The farm's name: a business.
        let farm: String
        /// Who sent it; nil once their account was pseudonymised by erasure.
        let person: String?
        /// In full, to be forwarded. NIL IS A FAULT, not an empty message:
        /// the server could not open the farm's key and sent nothing rather
        /// than ciphertext. Never shown as blank.
        let message: String?
        let consentedAt: Date?
        let createdAt: Date?
        let status: Status

        enum Status: String, LenientDecodable, Sendable {
            case pending = "PENDING", contacted = "CONTACTED", closed = "CLOSED"
            case unknown = "__unknown__"
            static var unknownCase: Self { .unknown }

            var label: String {
                switch self {
                case .pending: "Ново"
                case .contacted: "Свързани"
                case .closed: "Затворено"
                case .unknown: "—"
                }
            }
        }

        private enum CodingKeys: String, CodingKey { case id, farm, person, message, consentedAt, createdAt, status }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            farm = try c.decode(String.self, forKey: .farm)
            person = (try? c.decodeIfPresent(String.self, forKey: .person))?.recorded
            // A sealed envelope that arrives anyway is the same fault.
            message = (try? c.decodeIfPresent(String.self, forKey: .message))
                .flatMap { AssistantMemoryAPI.Conversation.isSealed($0) ? nil : $0 }
            consentedAt = (try? c.decodeIfPresent(String.self, forKey: .consentedAt)).flatMap(BgDate.parseInstant)
            createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(BgDate.parseInstant)
            status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .unknown
        }
    }

    static func decodeLeads(from data: Data) async throws -> [Lead] {
        struct Envelope: Decodable { let leads: [Lead] }
        return try await APIClient.shared.decode(data, as: Envelope.self).leads
    }

    /// Live, never cached: what farms wrote, with who wrote it.
    static func leads(_ id: String) async throws -> [Lead] {
        try await decodeLeads(from: APIClient.shared.data(for: leadsPath(id)))
    }

    // MARK: - The draft that is sent

    /// One promotion as the form holds it, sent as the routes take it.
    ///
    /// ── The ПРЗ number ──
    ///
    /// On an edit, an OMITTED `pppRegistrationNo` keeps the classification
    /// and an explicit null clears it: a plant protection product would
    /// stop being one. So it travels only when the person changed it
    /// (`pppChanged`), never because the form sends every field: fixing a
    /// typo in a title must not declassify a pesticide (backend 1).
    struct Draft: Equatable, Sendable {
        var companyId: String?
        var companyName = ""
        var title = ""
        var body = ""
        var category: PromotionsAPI.Category = .products
        var ctaUrl = ""
        var validFrom: Date?
        var validTo: Date?
        var pppRegistrationNo = ""
        var pppChanged = false

        static func from(_ promotion: Promotion) -> Draft {
            Draft(companyId: promotion.companyId, companyName: promotion.companyName, title: promotion.title,
                  body: promotion.body ?? "", category: promotion.category, ctaUrl: promotion.ctaUrl ?? "",
                  validFrom: promotion.validFrom, validTo: promotion.validTo,
                  pppRegistrationNo: promotion.pppRegistrationNo ?? "")
        }

        /// The request body. A day as a day key, `YYYY-MM-DD`, `validTo`
        /// inclusive: the server turns it into the farm's day, once.
        func payload(creating: Bool) -> Payload {
            Payload(companyId: companyId,
                    companyName: companyId == nil ? companyName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: body.recorded, category: category == .other ? .products : category,
                    ctaUrl: ctaUrl.recorded,
                    validFrom: validFrom.map(BgDate.isoDay), validTo: validTo.map(BgDate.isoDay),
                    ppp: (creating || pppChanged) ? .some(pppRegistrationNo.recorded) : .none)
        }

        var canSave: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (companyId != nil || !companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && !(validFrom.flatMap { from in validTo.map { $0 < from } } ?? false)
        }
    }

    struct Payload: Encodable, Equatable, Sendable {
        let companyId: String?
        let companyName: String?
        let title: String
        let body: String?
        let category: PromotionsAPI.Category
        let ctaUrl: String?
        let validFrom: String?
        let validTo: String?
        /// `.none`: not sent at all. `.some(nil)`: sent as null, which clears.
        let ppp: String??

        private enum CodingKeys: String, CodingKey {
            case companyId, companyName, title, body, category, ctaUrl, validFrom, validTo, pppRegistrationNo
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(companyId, forKey: .companyId)
            try c.encodeIfPresent(companyName, forKey: .companyName)
            try c.encode(title, forKey: .title)
            try c.encode(body, forKey: .body)
            try c.encode(category.rawValue, forKey: .category)
            try c.encode(ctaUrl, forKey: .ctaUrl)
            try c.encode(validFrom, forKey: .validFrom)
            try c.encode(validTo, forKey: .validTo)
            if case .some(let value) = ppp { try c.encode(value, forKey: .pppRegistrationNo) }
        }
    }

    // MARK: - Calls (all writes outward-facing)

    static func decodeList(from data: Data) async throws -> [Promotion] {
        struct Envelope: Decodable { let promotions: [Lossy] }
        struct Lossy: Decodable {
            let value: Promotion?
            init(from decoder: Decoder) throws { value = try? Promotion(from: decoder) }
        }
        return try await APIClient.shared.decode(data, as: Envelope.self).promotions.compactMap(\.value)
    }

    static func list() async throws -> [Promotion] {
        try await decodeList(from: APIClient.shared.data(for: listPath))
    }

    static func companies() async throws -> [Company] {
        struct Envelope: Decodable { let companies: [Company] }
        let data = try await APIClient.shared.data(for: companiesPath)
        return try await APIClient.shared.decode(data, as: Envelope.self).companies
    }

    private struct Created: Decodable, Sendable { let id: String }

    /// A DRAFT: nothing reaches a farm until it is published.
    static func create(_ draft: Draft) async throws -> String {
        let data = try await APIClient.shared.postReturningData(
            listPath, body: draft.payload(creating: true), idempotencyKey: nil)
        return try await APIClient.shared.decode(data, as: Created.self).id
    }

    static func update(_ id: String, _ draft: Draft) async throws {
        _ = try await APIClient.shared.patchReturningData(promotionPath(id), body: draft.payload(creating: false))
    }

    private struct Publish: Encodable, Sendable { let published: Bool }

    /// Publishing is the review act; taking it down is the same verb.
    static func setPublished(_ id: String, _ published: Bool) async throws {
        _ = try await APIClient.shared.putReturningData(promotionPath(id), body: Publish(published: published))
    }

    /// Only an offer nobody has asked about (`leadCount` 0): the server
    /// refuses the rest, and the screen offers «Свали» for them instead.
    static func delete(_ id: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(promotionPath(id))
    }

    static func uploadImage(_ id: String, jpeg: Data) async throws {
        _ = try await APIClient.shared.postMultipart(
            imagePath(id), file: jpeg, fileName: "promotion.jpg", mimeType: "image/jpeg")
    }

    static func removeImage(_ id: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(imagePath(id))
    }

    struct CompanyEdit: Encodable, Equatable, Sendable {
        let name: String
        let eik: String?
        let websiteUrl: String?
        let contactName: String?
        let contactEmail: String?
        let contactPhone: String?
        let notes: String?
    }

    static func updateCompany(_ id: String, _ edit: CompanyEdit) async throws {
        _ = try await APIClient.shared.patchReturningData(companyPath(id), body: edit)
    }

    /// A leaflet, read: proposals only; nothing is created or published.
    static func scanLeaflet(_ file: Data, fileName: String, mimeType: String) async throws -> LeafletScan {
        let data = try await APIClient.shared.postMultipart(
            leafletScanPath, file: file, fileName: fileName, mimeType: mimeType)
        return try await APIClient.shared.decode(data, as: LeafletScan.self)
    }
}
