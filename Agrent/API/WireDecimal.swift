import Foundation

/// A Prisma `Decimal` off this API, which is a NUMBER on some endpoints and
/// a STRING on others.
///
/// ── The rule, and it is not the one either of us reached for first ──
///
/// A `Decimal` column reaches JSON as a string, because that is what
/// `JSON.stringify` does to one. But an endpoint that maps its row through
/// a DTO converts it back to a number on the way past:
///
///     function dec(v) { return typeof v === 'number' ? v : Number(v.toString()) }
///
/// So the honest rule is **per-endpoint**: a Decimal is a string unless the
/// route maps through a DTO, and whether it does is a property of that
/// route. Measured, both ways, on this tenant:
///
///     grain/costs        amount           → 1        NUMBER  (toDto)
///     exchange/listings  quantityTonnes   → "12.5"   STRING  (no DTO)
///
/// Two endpoints, one database type, two wire types. This accepts both,
/// which is not defensive vagueness — it is the actual contract.
///
/// ── Why `Decimal` and not `Double` ──
///
/// This is money. `0.1 + 0.2` is not `0.3` in binary floating point, and a
/// calculator that disagrees with a farm's books in the third decimal is
/// one nobody uses twice. `Foundation.Decimal` is base-10 and exact at
/// these magnitudes. The string branch parses straight to `Decimal` and the
/// number branch decodes straight to `Decimal`; neither goes via `Double`.
///
/// ── Scale comes from the COLUMN, not the value ──
///
/// `1.00` arrives as `1`, whether as a number or as a string that lost its
/// trailing zero. Rendering it through gives `1 лв` where the books say
/// `1,00`. So display takes the scale from the column it came from:
///
///     CostEntry.amount         Decimal(14,2)
///     YieldRecord.grossTonnes  Decimal(14,3)
///     YieldRecord.moisturePct  Decimal(5,2)
///     YieldRecord.areaHa       Decimal(12,4)
///
struct WireDecimal: Decodable, Equatable, Sendable {
    let value: Decimal

    /// The digits as the server sent them, kept for diagnosis. NOT for
    /// display — that is what `text(scale:)` is for.
    let raw: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // A string is the documented shape. A number is accepted anyway:
        // the same value is `z.number()` on the way in, and a route that
        // echoes a create back before it round-trips the database would
        // hand back what it was given. Refusing it would fail a whole
        // payload over a field the app can read perfectly well.
        if let text = try? container.decode(String.self) {
            guard let parsed = Decimal(string: text, locale: Self.wireLocale) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not a decimal: \(text)"
                ))
            }
            self.value = parsed
            self.raw = text
            return
        }

        // NOT `Double`. Going through binary floating point is the one thing
        // this type exists to avoid, and it would happen silently.
        let number = try container.decode(Decimal.self)
        self.value = number
        self.raw = "\(number)"
    }

    /// Parse a wire string without decoding, for models that hold the raw
    /// string and expose a computed `Decimal`.
    static func parse(_ text: String?) -> Decimal? {
        guard let text else { return nil }
        return Decimal(string: text, locale: wireLocale)
    }

    init(_ value: Decimal) {
        self.value = value
        self.raw = "\(value)"
    }

    /// JSON numbers and Prisma's strings both use `.` regardless of the
    /// device's locale. Parsing with `Locale.current` would read "1234.5" as
    /// 12345 on a machine that uses `.` for grouping — which is a real
    /// locale, and the failure is a factor of ten in a financial figure.
    static let wireLocale = Locale(identifier: "en_US_POSIX")

    /// Formatted for an operator, in Bulgarian, at the column's scale.
    ///
    /// Padded to `scale` rather than trimmed to it: the server's string has
    /// already dropped trailing zeros, so `"1234.5"` at scale 2 must come
    /// back out as `1234,50`.
    func text(scale: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(scale))
                .grouping(.automatic)
                .locale(BgDate.locale)
        )
    }
}
