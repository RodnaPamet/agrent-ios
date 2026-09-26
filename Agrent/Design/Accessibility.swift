import CoreGraphics
import Foundation
import SwiftUI

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
extension View {
    /// ONE SPOKEN SENTENCE FOR VOICEOVER, AND A SHORT NAME TO SAY OUT LOUD.
    ///
    /// ── The trade-off this exists to stop making silently ──
    ///
    /// `A11y.sentence` + `children: .ignore` is right for VoiceOver: it turns a
    /// row into one stop and keeps the `·` out of the audio channel. It is
    /// ALSO, unavoidably, what removes the row's short visible name from the
    /// set of phrases Voice Control will accept. A user who says «Пшеница»
    /// gets nothing, because the only name that element has is
    /// «Пшеница, продава, 250 тона, 51,13 евро на тон.»
    ///
    /// Voice Control matches on `accessibilityInputLabels` when they exist and
    /// falls back to the label when they do not — so the two technologies want
    /// different strings and both can be given. Every row in this app declared
    /// the first and none declared the second, because nothing tied them
    /// together.
    ///
    /// This does. A row that adopts the house pattern gets both or neither,
    /// and the short name is a parameter rather than something to remember.
    ///
    /// `spoken` is what VoiceOver reads; `saying` is what a person can say —
    /// the words actually printed on screen, shortest first, because Voice
    /// Control shows the first match in its label overlay.
    func accessibleRow(spoken: String, saying: [String]) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityInputLabels(saying.filter { !$0.isEmpty })
    }
}

enum A11y {

    /// WHAT A CONTROL CAN BE CALLED, in both languages.
    ///
    /// ── Voice Control listens in the PHONE's language, not the app's ──
    ///
    /// This app is Bulgarian by declaration and every name in it is
    /// Bulgarian. Voice Control's recogniser follows the device language,
    /// and this owner's phone reports `en_BG` — English language, Bulgarian
    /// region, an ordinary thing for a person to set, and the same setting
    /// that made `BgDate` necessary. On it, Voice Control runs in English:
    /// the labels are visible, correct, and unsayable. Saying «Покажи» to an
    /// English recogniser produces nothing.
    ///
    /// `accessibilityInputLabels` takes a LIST of alternatives, so a control
    /// can answer to both. Bulgarian stays FIRST — it is what appears when a
    /// user turns on "Show Names", and it is what the screen says.
    ///
    /// ── What this does not reach ──
    ///
    /// Only controls with an explicit input label. Everywhere else Voice
    /// Control falls back to the accessibility label, which is Bulgarian, so
    /// an English recogniser cannot name those either. The platform's own way
    /// out is "Show Numbers" — an overlay that puts a number on every control
    /// — and that works whatever the language. This makes the controls a
    /// person is most likely to reach for directly sayable without it.
    ///
    /// Only for FIXED names. A news headline and a price series are data;
    /// they have no English form worth inventing, and `NewsView` and
    /// `TrendsView` pass them through as they are. A commodity is the
    /// exception, because the server's own slug IS the English word.
    ///
    /// Case-insensitively deduplicated, so passing a name that happens to be
    /// the same in both does not register it twice.
    static func spokenNames(_ names: String?...) -> [String] {
        var seen = Set<String>()
        return names
            .compactMap { $0?.recorded }
            .filter { seen.insert($0.lowercased()).inserted }
    }

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
