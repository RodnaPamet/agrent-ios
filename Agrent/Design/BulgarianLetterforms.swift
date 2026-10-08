import Foundation

/// Bulgarian first in the app's own language list (#205; owner,
/// 2026-10-08): the setting iOS's per-app Language option writes.
///
/// ── Why ──
///
/// SF Pro has Bulgarian shapes for д, т, л, в and others, and CoreText
/// picks them for text it knows is Bulgarian. Text that names no language
/// takes the first of the preferred languages. So on a phone that lists no
/// Bulgarian, everything drawn without a language came out in the standard
/// shapes, beside the Bulgarian shapes of text that names one: SwiftUI's
/// text in every sheet, UIKit's alerts and bars, Apple's sign-in button.
/// `.typesettingLanguage` at the root reaches SwiftUI's text on the main
/// screens but not into sheets. This reaches all of it.
///
/// ── When ──
///
/// Before the first text is laid out: `AgrentApp.init`, ahead of
/// `BulgarianLayout`, whose priming should measure the shapes the app will
/// draw. Probed on a fresh install on 2026-10-08: set there, it holds from
/// the first launch, sheets included.
///
/// The rest of the phone's list stays behind it, for the system strings a
/// framework has no Bulgarian for.
enum BulgarianLetterforms {
    static let key = "AppleLanguages"

    /// `languages` with Bulgarian first. A list already led by Bulgarian is
    /// returned as it is.
    static func preferringBulgarian(_ languages: [String]) -> [String] {
        if let first = languages.first, isBulgarian(first) { return languages }
        return ["bg"] + languages.filter { !isBulgarian($0) }
    }

    /// Idempotent: writes only when the list does not already lead with
    /// Bulgarian, so a launch after the first writes nothing.
    static func install(_ defaults: UserDefaults = .standard) {
        let current = defaults.stringArray(forKey: key) ?? []
        let preferred = preferringBulgarian(current)
        if preferred != current { defaults.set(preferred, forKey: key) }
    }

    private static func isBulgarian(_ identifier: String) -> Bool {
        identifier == "bg" || identifier.hasPrefix("bg-") || identifier.hasPrefix("bg_")
    }
}
