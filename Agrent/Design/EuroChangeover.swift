import Foundation

/// The lev's fixed rate to the euro, for a figure the farm entered in leva.
///
/// Bulgaria has used the euro since 1 January 2026, and costs default to EUR
/// (owner, 2026-10-10). A farm's own last values can still be in leva:
/// entries made before the changeover, or since in the old currency. Prefilled
/// under EUR as they stand, a 24 000 лв. salary would read as €24 000, about
/// twice the real figure, on the farm's books.
///
/// ── A legal constant, not an exchange rate ──
///
/// 1 € = 1,95583 лв. is the conversion rate fixed by the Council of the EU
/// for the changeover, irrevocably. That is why it may be applied here when
/// no other rate is: there is no market and no date in it. Any other pair has
/// no fixed rate, and a figure in one is left out rather than converted at a
/// guess.
enum EuroChangeover {
    static let levaPerEuro = Decimal(string: "1.95583")!

    /// `amount` in `currency`, expressed in `target`: as it stands when the
    /// two match, at the fixed rate from BGN to EUR, and nil for any other
    /// pair. Rounded to the cent, the scale costs are stored at.
    static func convert(_ amount: Decimal, from currency: String, to target: String) -> Decimal? {
        let from = currency.uppercased(), to = target.uppercased()
        if from == to { return amount }
        guard from == "BGN", to == "EUR" else { return nil }
        var exact = amount / levaPerEuro
        var cents = Decimal()
        NSDecimalRound(&cents, &exact, 2, .plain)
        return cents
    }
}
