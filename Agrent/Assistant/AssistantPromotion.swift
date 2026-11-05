import SwiftUI

/// A promotion under an answer (#508, agri-saas #2665): its own block,
/// marked «Промоция», never part of the advice (owner, 2026-11-01: "marked
/// as a promotion and kept separate from its advice").
///
/// The server builds it from the reviewed catalogue, not the model, and
/// tells the model not to repeat it, so the answer's text never carries it.
/// Every field is a value, shown as one.
///
/// ── The safety wording ──
///
/// For a plant protection product, `safetyWording` is Reg. (EC) 1107/2009
/// Art 66's prescribed text. Non-null means it MUST be shown, in full and as
/// its own line: the server drops a promotion whose wording it could not
/// resolve rather than send it without one. Null means no wording applies
/// (not a ПРЗ), which is not the same as missing, so the decoder never
/// turns either into an empty string.
struct AssistantPromotion: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    /// On whose behalf (DSA Art 26), the advertiser's legal name verbatim.
    let company: String
    let product: String
    let details: String?
    /// Nil is an open campaign, not a stale one.
    let validTo: Date?
    let safetyWording: String?

    private enum CodingKeys: String, CodingKey { case id, company, product, details, validTo, safetyWording }

    init(id: String, company: String, product: String, details: String? = nil, validTo: Date? = nil,
         safetyWording: String? = nil) {
        self.id = id
        self.company = company
        self.product = product
        self.details = details
        self.validTo = validTo
        self.safetyWording = safetyWording
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        company = try c.decode(String.self, forKey: .company)
        product = try c.decode(String.self, forKey: .product)
        details = (try? c.decodeIfPresent(String.self, forKey: .details))?.recorded
        validTo = (try? c.decodeIfPresent(String.self, forKey: .validTo)).flatMap(BgDate.parseInstantOrDay)
        // Strict: a wording that is there but unreadable fails the
        // promotion (and so drops it), never shows it without one.
        safetyWording = try c.decodeIfPresent(String.self, forKey: .safetyWording)
    }

    /// The array as it arrives: a promotion that does not read costs that
    /// promotion, never the answer.
    struct Lossy: Decodable {
        let value: AssistantPromotion?
        init(from decoder: Decoder) throws { value = try? AssistantPromotion(from: decoder) }
    }

    /// What VoiceOver reads: the block as one element, starting «Промоция»,
    /// and never merged with the answer.
    var spoken: String {
        A11y.sentence([AssistantPromotionText.from(company), product, details,
                       validTo.map { AssistantPromotionText.until($0) }, safetyWording])
    }
}

/// One promotion, drawn under the answer.
struct AssistantPromotionView: View {
    let promotion: AssistantPromotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AssistantPromotionText.from(promotion.company))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            Text(promotion.product)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let details = promotion.details {
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let until = promotion.validTo {
                Text(AssistantPromotionText.until(until))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
            if let wording = promotion.safetyWording {
                Text(wording)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.Surface.edge, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(promotion.spoken)
    }
}

enum AssistantPromotionText {
    /// «Промоция от <company>»: what it is, and on whose behalf.
    static func from(_ company: String) -> String { "Промоция от \(company)" }

    /// «до 30 ноември», with the year when it is not this one.
    static func until(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return "до \(sameYear ? BgDate.dayMonth(day) : BgDate.full(day))"
    }
}
