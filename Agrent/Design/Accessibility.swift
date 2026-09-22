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

    /// Where a parcel sits relative to the rest of the farm, in words.
    ///
    /// This exists because the schematic map's ONE piece of information that
    /// no list beneath it carries is position — which field is north of which,
    /// and how far apart. Shape is deliberately false there and absolute size
    /// is five times life; position is the part still true, and until now it
    /// reached exactly one sense. A single `accessibilityLabel` on the canvas
    /// ("4 парцела, 2 засети") summarises the data the list already gives
    /// better, and drops the only thing the map uniquely knows.
    ///
    /// Screen space, so `dy` grows SOUTHWARD — the sign flip is the whole
    /// trap. The projection is linear, so a bearing taken here equals one
    /// taken in degrees, and this needs no second coordinate system.
    ///
    /// Returns nil at the centre rather than inventing a direction: with one
    /// parcel, or with a parcel genuinely in the middle, every answer is
    /// wrong and "в средата" is the honest one. The caller decides how to say
    /// that, because "the only parcel" and "the middle parcel" are different
    /// sentences.
    static func compass(dx: CGFloat, dy: CGFloat, deadband: CGFloat) -> String? {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance.isFinite, distance > deadband, deadband.isFinite else { return nil }

        // atan2 with dy NEGATED, because north is up and y is down.
        let angle = atan2(-dy, dx)
        let step = CGFloat.pi / 4
        var sector = Int((angle / step).rounded()) % 8
        if sector < 0 { sector += 8 }

        return [
            "изток", "североизток", "север", "северозапад",
            "запад", "югозапад", "юг", "югоизток",
        ][sector]
    }
}
