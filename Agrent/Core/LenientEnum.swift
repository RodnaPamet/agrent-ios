import Foundation

/// A string enum that degrades instead of throwing.
///
/// `LogEntryType` is why this exists. It shipped six cases against the
/// server's ten, and because `LogEntry.type` is non-optional a single
/// unrecognised value would have failed the ENTIRE list decode — every row
/// vanishing, not just the odd one. It had not bitten only because the live
/// tenant happened to hold nothing but the two types the app knew.
///
/// Every wire enum added since adopts this instead: an unrecognised value
/// costs a vague label on one field, never the screen.
///
/// Matching is case-insensitive as cheap defence. That is NOT because any
/// server has been observed mixing conventions — one earlier claim to that
/// effect turned out to be a defect in a test fixture, and was retracted.
///
/// `LogEntryType` adopts it too now, with an `.unknown` that is read and never
/// written; `LogEntryStatus` followed (agrent-ios#182), since the spec types
/// `LogEntry.status` as a free string.
protocol LenientDecodable: RawRepresentable, CaseIterable, Decodable
where RawValue == String {
    /// Returned for any value this build does not recognise.
    static var unknownCase: Self { get }
}

extension LenientDecodable {
    /// An unrecognised value — AND A JSON `null` — is `unknownCase`.
    ///
    /// Null too, since agrent-ios#182: the spec makes `Task.severity` and
    /// `Task.priority` nullable, and a non-optional enum that threw on null
    /// failed the whole task detail for one empty column. A field that can
    /// genuinely be absent is still declared optional — `decodeIfPresent`
    /// answers nil before this runs — so this changes only what a NON-optional
    /// field does with a null: it degrades, as it does for a value it does
    /// not know.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = Self.unknownCase
            return
        }
        let raw = try container.decode(String.self)
        let folded = raw.lowercased()
        self = Self.allCases.first { $0.rawValue.lowercased() == folded } ?? Self.unknownCase
    }
}
