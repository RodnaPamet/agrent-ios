import Foundation

/// Bulgarian counting forms, as plain strings.
///
/// ── Why not `^[…](inflect: true)` ──
///
/// Automatic grammar agreement works only when the markup reaches `Text`
/// as a LITERAL `LocalizedStringKey`. Build the same string in a variable
/// and pass it along, and `Text(_ content: String)` wins the overload —
/// the markup is never processed and the operator reads it raw.
///
/// Measured on the device: the admin screen rendered
///
///     ^[7 активни сесии](inflect: true)
///
/// verbatim, on screen, in production data. Eleven sites in this app used
/// the markup and four of them reached `Text` as a literal. The other
/// seven did not, and nothing failed — the failure mode of this feature
/// is silent output, which is why it survived a design pass and an
/// accessibility pass.
///
/// ── And it can never work in an accessibility label ──
///
/// An `accessibilityLabel` takes a `String`. Two of the seven were inside
/// `A11y.sentence(…)`, so VoiceOver would have spoken the markup aloud —
/// invisible to everyone who can see the screen, which is the same class
/// of defect as the date that read "September" to VoiceOver while showing
/// "септември".
///
/// So: one mechanism, explicit forms, correct in both places and testable
/// without a rendering pass.
///
/// ── The rule ──
///
/// Bulgarian nouns take a counting form after a numeral: one запис, two
/// записа. Masculine nouns mostly add -а/-я; the rest vary, so both forms
/// are given at the call site rather than derived. A derivation that is
/// right for four nouns and wrong for the fifth is worse than typing the
/// fifth.
enum Plural {
    /// `Plural.bg(1, "запис", "записа")` → "1 запис"
    /// `Plural.bg(7, "сесия", "сесии")` → "7 сесии"
    static func bg(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}
