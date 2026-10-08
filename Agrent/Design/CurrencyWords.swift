import Foundation

/// A currency as Bulgarian prose says it: «евро», «долар», «лева».
///
/// Trends had this table privately, for its unit headings — «евро на тон»
/// over a chart, «512 долара на тон» after a price — while Борса spoke the
/// ISO code, «51,13 EUR на тон», which a Bulgarian voice reads out as
/// three letters (#220). One table now, for what Trends prints and for
/// what Борса says.
///
/// Only the dollar changes after a number: «евро» does not inflect and
/// «лева» already is the counting form (the old table used it for the
/// heading too, and it stays for parity). Bulgarian counts in the plural
/// and a price is practically never exactly one, so «1 долар» is not
/// attempted.
///
/// A currency without a Bulgarian name here keeps its ISO code: «RON на
/// тон» is neutral, a guessed «леи» is a claim (same rule as a region).
enum CurrencyWords {
    static func name(_ code: String, afterNumber: Bool) -> String {
        switch code.uppercased() {
        case "EUR": "евро"
        case "USD": afterNumber ? "долара" : "долар"
        case "BGN": "лева"
        default: code
        }
    }
}
