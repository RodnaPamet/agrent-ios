import Foundation

/// «Промоции» (#528): the published supplier offers every farm sees, and a
/// farm's «Поискай оферта» to one of them (agri-saas #2725).
///
/// One catalogue for all farms, which is why nothing in it is the farm's
/// own: it is supplier advertising, cached per user and farm like any list
/// and revalidated by its ETag. The request a farm sends is the opposite: a
/// message to a THIRD PARTY, so it is built here and never sent from
/// development, CI or the screenshots. The owner makes the first real one.
enum PromotionsAPI {
    static var listPath: String { "\(FarmPath.root)/offers" }
    static var leadsPath: String { "\(FarmPath.root)/offers/leads" }
    /// The picture, served by agri-saas from its own route: `mediaUrl` is
    /// always this path or null, never an off-site URL (backend 1, asserted
    /// by a test on the server), so the request carrying the person's
    /// bearer never leaves app.agrent.bg.
    static func imagePath(_ id: String) -> String { "/api/promotions/\(URLEscape.segment(id))/image" }

    /// The curated five, in the web's words (`ag.offers.cat*`). Anything else
    /// is someone writing past the schema: shown as «Друго», never a failed
    /// list.
    enum Category: String, LenientDecodable, Sendable {
        case culture, fertilizer, seeds, products, service
        case other = "__other__"

        static var unknownCase: Self { .other }

        var label: String {
            switch self {
            case .culture: "Култура"
            case .fertilizer: "Тор"
            case .seeds: "Семена"
            case .products: "Продукти"
            case .service: "Услуга"
            case .other: "Друго"
            }
        }
    }

    struct Promotion: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let company: String
        let title: String
        /// Plain text: the server sanitises it on every write.
        let body: String?
        let category: Category
        /// Root-relative (`imagePath`) or nil.
        let mediaUrl: String?
        /// The supplier's own page, opened in the in-app browser.
        let ctaUrl: URL?
        /// The campaign's last day, inclusive, as the farm's day
        /// (`YYYY-MM-DD` in the farm's zone, agri-saas #2725): read as a day,
        /// never an instant, so «2 ноември» is not the 1st in Sofia.
        let validTo: Date?
        /// This farm has asked already: «Поискай оферта» is not offered
        /// again (one request per farm per offer on the server).
        var hasRequested: Bool

        private enum CodingKeys: String, CodingKey {
            case id, company, title, body, category, mediaUrl, ctaUrl, validTo, hasRequested
        }

        init(id: String, company: String, title: String, body: String? = nil, category: Category = .products,
             mediaUrl: String? = nil, ctaUrl: URL? = nil, validTo: Date? = nil, hasRequested: Bool = false) {
            self.id = id
            self.company = company
            self.title = title
            self.body = body
            self.category = category
            self.mediaUrl = mediaUrl
            self.ctaUrl = ctaUrl
            self.validTo = validTo
            self.hasRequested = hasRequested
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = try c.decode(String.self, forKey: .id)
            self.id = id
            company = try c.decode(String.self, forKey: .company)
            title = try c.decode(String.self, forKey: .title)
            body = (try? c.decodeIfPresent(String.self, forKey: .body))?.recorded
            category = (try? c.decodeIfPresent(Category.self, forKey: .category)) ?? .other
            // Only the server's own picture route: anything else is not
            // fetched with the person's bearer.
            mediaUrl = (try? c.decodeIfPresent(String.self, forKey: .mediaUrl))
                .flatMap { $0 == PromotionsAPI.imagePath(id) ? $0 : nil }
            ctaUrl = (try? c.decodeIfPresent(String.self, forKey: .ctaUrl))
                .flatMap(URL.init(string:)).flatMap { InAppBrowser.opens($0) ? $0 : nil }
            validTo = (try? c.decodeIfPresent(String.self, forKey: .validTo)).flatMap(BgDate.parseISODay)
            hasRequested = (try? c.decodeIfPresent(Bool.self, forKey: .hasRequested)) ?? false
        }
    }

    /// A promotion that does not read costs that promotion, never the list.
    static func decodeList(from data: Data) async throws -> [Promotion] {
        struct Envelope: Decodable { let offers: [Lossy] }
        struct Lossy: Decodable {
            let value: Promotion?
            init(from decoder: Decoder) throws { value = try? Promotion(from: decoder) }
        }
        return try await APIClient.shared.decode(data, as: Envelope.self).offers.compactMap(\.value)
    }

    /// The longest message the server takes.
    static let maxMessage = 2000

    private struct Lead: Encodable, Sendable {
        let promotionId: String
        let message: String
        /// `z.literal(true)` on the server: a request without the person's
        /// recorded consent cannot be stored at all, so the phone sends
        /// `true` only from a tick the person made.
        let consent: Bool
    }

    /// «Поискай оферта». OUTWARD-FACING: it goes to a supplier. Never called
    /// from development, CI or A11yShots.
    static func sendLead(promotionId: String, message: String) async throws {
        _ = try await APIClient.shared.postReturningData(
            leadsPath, body: Lead(promotionId: promotionId, message: message, consent: true), idempotencyKey: nil)
    }

    /// Asked already, from this phone or another: what the person wanted is
    /// done, so the card says «Заявката е изпратена».
    static func isAlreadySent(_ error: Error) -> Bool {
        if case APIClient.APIError.http(409, "PROMOTION_LEAD_ALREADY_SENT"?, _, _, _) = error { return true }
        return false
    }

    /// The card was stale: withdrawn, not started, or past its last day.
    /// The list is read again.
    static func isNoLongerRunning(_ error: Error) -> Bool {
        if case APIClient.APIError.http(404, let code?, _, _, _) = error {
            return code == "PROMOTION_NOT_AVAILABLE" || code == "PROMOTION_NOT_FOUND"
        }
        return false
    }
}
