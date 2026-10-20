import Foundation

/// What «Продължи» works out before «Добави» (agrent-ios#362): the amount of
/// product the dose and the treated area add up to, as PRZ's check screen
/// shows it (owner, 2026-10-20).
///
/// No remaining stock: a ДНЕВНИК treatment deducts none (agri-saas #1740),
/// and the owner didn't ask for it.
enum TreatmentCheck {
    /// An amount in the dose's own quantity — «70,4 л».
    struct Amount: Equatable, Sendable {
        let value: Double
        /// The dose unit's numerator: «л», «кг», «г» or «мл».
        let unit: String

        var text: String { "\(Num.text(value)) \(unit)" }

        /// «70,4 литра». VoiceOver spells a symbol letter by letter; a unit
        /// outside the four is said as its symbol, never left out.
        var spoken: String {
            let one = value == 1
            let word = switch unit {
            case "л": one ? "литър" : "литра"
            case "мл": one ? "милилитър" : "милилитра"
            case "кг": one ? "килограм" : "килограма"
            case "г": one ? "грам" : "грама"
            default: unit
            }
            return "\(Num.text(value)) \(word)"
        }
    }

    /// The dose times the treated area, in the dose unit's quantity. nil
    /// when the unit isn't a rate per area, or there is no area to multiply:
    /// the screen then says the amount can't be worked out, never a guess.
    ///
    /// By the unit's SYMBOL: `/units?measure=RATE` sends four, all per
    /// decare (г/дка, кг/дка, л/дка, мл/дка), and no conversion factor.
    /// Per hectare is read too, in case one is added.
    static func amount(dose: Decimal, unitSymbol: String, area: Area) -> Amount? {
        let parts = unitSymbol.split(separator: "/", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let size: Double
        switch parts[1].lowercased() {
        case "дка", "daa": size = area.decares
        case "ха", "ha": size = area.wireHectares
        default: return nil
        }
        guard size > 0 else { return nil }
        let value = NSDecimalNumber(decimal: dose).doubleValue * size
        // A thousand of the small unit is read as the large one, as product
        // is bought and measured out: «1,5 л», not «1500 мл».
        switch parts[0] {
        case "мл" where value >= 1000: return Amount(value: value / 1000, unit: "л")
        case "г" where value >= 1000: return Amount(value: value / 1000, unit: "кг")
        default: return Amount(value: value, unit: parts[0])
        }
    }

    /// «Най-ранна дата за прибиране»: the treatment day plus the quarantine
    /// period, as the ДНЕВНИК computes it (`buildChemicalRows`).
    static func earliestHarvest(after day: Date, days: Int) -> Date? {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: day)
    }
}
