import Foundation

/// A crop «Нов разход» can book against: one the calculator reports, with
/// the land it stands on (#245).
///
/// From `CalculatorRow`, whose `commodity` is a canonical slug, a closed set.
/// So a ley («Grass» in the parcel picker) is never one: it resolves to no
/// commodity, and the server would refuse a cost against it.
struct CropChoice: Equatable, Hashable, Identifiable, Sendable {
    let commodity: String
    /// The decares the crop OCCUPIES (agri-saas #1606, `occupiedAreaHa`):
    /// what a per-decare figure is multiplied by.
    let areaDca: Decimal

    var id: String { commodity }
    var name: String { CommodityName.canonical(commodity) ?? commodity }

    /// The crops with land to spread a rate over, in the calculator's order.
    /// One with no land is left out: a rate × 0 dca is a cost of nothing,
    /// which the server refuses, and «0 дка» offered as a choice would ask
    /// the farmer to make it.
    static func from(_ rows: [CalculatorRow]) -> [CropChoice] {
        rows.compactMap { row in
            guard let hectares = row.occupiedAreaHa, hectares > 0,
                  let decares = decares(hectares: hectares), decares > 0 else { return nil }
            return CropChoice(commodity: row.commodity, areaDca: decares)
        }
    }

    /// Hectares as decares, through the number's own digits: `Decimal(12.34)`
    /// would carry the binary 12.339999…, and the cents of every line with it.
    static func decares(hectares: Double) -> Decimal? {
        Decimal(string: String(hectares), locale: WireDecimal.wireLocale).map { $0 * 10 }
    }
}
