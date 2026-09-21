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
/// `LogEntryType` itself deliberately does NOT adopt this. Its strictness is
/// asserted by a test that documents the consequence, and loosening it would
/// silently change what a journal list does when the server adds a type. That
/// is a decision to take on purpose, not as a side effect of a refactor.
protocol LenientDecodable: RawRepresentable, CaseIterable, Decodable
where RawValue == String {
    /// Returned for any value this build does not recognise.
    static var unknownCase: Self { get }
}

extension LenientDecodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let folded = raw.lowercased()
        self = Self.allCases.first { $0.rawValue.lowercased() == folded } ?? Self.unknownCase
    }
}
