import CoreGraphics
import Foundation
import SwiftUI

/// The things a screen reader needs that a sighted reader gets from layout.
///
/// ── Why `·` is the recurring bug ──
///
/// Five screens build a subtitle as `Text(crop); Text("·"); Text(area)` — and
/// that count is why three of them kept a plain `HStack` through the Dynamic
/// Type pass: the sweep fixed the three rows it was looking at. All five go
/// through `MetaRow` now, and a CI step keeps the separator in one place. Read
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


    /// THE TOOLBAR VERBS, each with the English a Voice Control user would
    /// actually say to it.
    ///
    /// Twenty-eight sheet buttons, and nine of them are the same word. Saying
    /// «Отказ»/"Cancel" nine times at nine call sites is how the third and
    /// fourth spellings of it appear, so the words live here and the screens
    /// name one.
    ///
    /// WHY «ОТКАЗ» IS HERE AT ALL, when the owner's wording was "the main
    /// action on each screen". Taken literally that gives an English speaker
    /// a way to COMPLETE a sheet and no way to leave one — they open it by
    /// voice, then have to turn on Show Numbers to back out. A sheet that can
    /// only be finished is worse than one that was never sayable.
    ///
    /// «Запази» and «Запиши» are both "Save". Two Bulgarian verbs, one
    /// English one, and no screen shows both at once — so the ambiguity
    /// cannot arise where it would matter, and inventing a second English
    /// word for it would be worse than sharing one.
    enum Spoken {
        static let cancel = spokenNames("Отказ", "Cancel")
        static let close = spokenNames("Затвори", "Close")
        static let save = spokenNames("Запази", "Save")
        /// The operation sheet's own verb. "Save" as well — see above.
        static let record = spokenNames("Запиши", "Save")
        static let create = spokenNames("Създай", "Create")
        static let publish = spokenNames("Публикувай", "Post")
        static let send = spokenNames("Изпрати", "Send")
        static let done = spokenNames("Готово", "Done")
        static let importing = spokenNames("Импортирай", "Import")
        /// The farm profile's way into its editor.
        static let edit = spokenNames("Редактирай", "Edit")
        /// The unsaved-changes guard's way out. NOT `cancel`: «Отказ» is what
        /// opened this question, and the answer that throws the edits away
        /// must not answer to the same word that asked it.
        static let discard = spokenNames("Отхвърли промените", "Discard")

        // ── Exchange messaging (agrent-ios#114) ──
        //
        // NOT `send` and NOT `close`, and that is the reason these exist.
        // `OutboxBanner` sits above every tab and its button is «Изпрати» /
        // "Send", so a composer answering to the same two words would put two
        // controls on one screen under one spoken name — Voice Control then
        // numbers them, and the person who said "Send" has to read which is
        // which. «Затвори» / "Close" is every sheet's way out; a conversation
        // closed by a person trying to leave a sheet is closed for the other
        // farm too.

        /// The composer's send, which names its object.
        static let sendMessage = spokenNames("Изпрати съобщението", "Send message")
        /// A task's comment (#225) — a different send from a message, so a
        /// different name: one screen could one day hold both.
        static let sendComment = spokenNames("Изпрати коментара", "Send comment")
        /// The task screen's green tick (#226) — it only closes.
        static let closeTask = spokenNames("Затвори задачата", "Close task")
        /// Close THIS conversation — an act the other farm sees.
        static let closeConversation = spokenNames("Затвори разговора", "Close conversation")
        /// The house search field (#164) and its clear button.
        static let search = spokenNames("Търсене", "Search")
        static let clearSearch = spokenNames("Изчисти търсенето", "Clear search")
        static let block = spokenNames("Блокирай", "Block")
        static let unblock = spokenNames("Отблокирай", "Unblock")
        /// Retract one of the person's OWN messages (per person since agri-saas #1323).
        static let retract = spokenNames("Премахни", "Remove")

        // ── The account (agri-saas#1193 P2.8) ──
        //
        // «Профил» is Админ's account row — the card, or the plain row before
        // `/me` answers; «Изход» is the Профил page's row and the
        // confirmation's answer (neither is a menu row since 2026-10-07). One
        // word, because it is one act, and the dialog is modal, so two of them
        // are never live at once. Neither collides: no other control in the
        // app is «Профил» (the farm's page is reached through «Стопанство»),
        // and nothing else answers to "Profile" or "Sign out".
        static let profile = spokenNames("Профил", "Profile")
        static let signOut = spokenNames("Изход", "Sign out")
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
