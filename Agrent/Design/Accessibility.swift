import CoreGraphics
import Foundation

/// The things a screen reader needs that a sighted reader gets from layout.
///
/// ── Why `·` is the recurring bug ──
///
/// Five screens build a subtitle as `Text(crop); Text("·"); Text(area)`. Read
/// visually that is one line of facts. Read by VoiceOver it is three stops,
/// the middle one announced as "middle dot" — and `.accessibilityElement
/// (children: .combine)` does not fix it, it concatenates the children
/// INCLUDING the separator, so the operator hears "Пшеница middle dot 12,4
/// ха". The separator is typography; it should never reach the audio channel.
///
/// So facts are assembled ONCE, from the values rather than from the rendered
/// text, and the view declares that label explicitly with `children: .ignore`.
enum A11y {

    /// Join facts as speech: nils and blanks dropped, comma-separated, one
    /// full stop at the end so VoiceOver pauses instead of running into
    /// whatever follows.
    static func sentence(_ parts: [String?]) -> String {
        let kept = parts
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !kept.isEmpty else { return "" }
        let joined = kept.joined(separator: ", ")
        return joined.hasSuffix(".") ? joined : joined + "."
    }
}
