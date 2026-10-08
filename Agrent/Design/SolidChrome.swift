import SwiftUI
import UIKit

/// Opaque, token-coloured navigation and tab bars, for the whole process.
///
/// WHY NOT THE SYSTEM BARS. Both are translucent by default: a material
/// that takes its colour from whatever scrolls beneath it. Indoors that is
/// a refinement; in a field it is a title and five tab labels whose
/// background changes with every row — and on the parcel map, with every
/// satellite tile. DESIGN.md: "Prefer solid or near-solid surfaces for
/// anything carrying text." This is agri-saas#1193 P2.8's "solid surfaces".
///
/// WHY THE APPEARANCE PROXY and not `.toolbarBackground` per screen. Each
/// tab and each sheet owns its own `NavigationStack` — twenty of them — and
/// a modifier that has to be remembered at twenty sites is one that will be
/// missing from the twenty-first. The proxy reaches every bar, sheets
/// included, from one place. It is iOS 13 API; nothing here is newer than
/// the deployment target.
///
/// THE COLOURS ARE DYNAMIC. `Palette`'s colours are `UIColor` providers
/// that pick an arm from the trait collection, so one appearance serves
/// dark, light and «Слънце», and follows a settings change without a
/// relaunch.
///
/// WHAT THIS DOES NOT REACH: on iOS 26 the system draws its own glass
/// capsule behind bar BUTTONS (the menu button, «Затвори»). Turning that
/// off needs iOS 26 API, and this app targets iOS 17.
///
/// On the main actor as a whole (#195): every member builds or installs
/// UIKit appearance, which is main-actor API.
@MainActor
enum SolidChrome {

    /// Idempotent. Called from `AgrentApp.init()`, before any bar exists —
    /// the proxy only styles bars created after it is set.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let navigation = UINavigationBar.appearance()
        navigation.standardAppearance = navigationAppearance()
        navigation.compactAppearance = navigationAppearance()
        // AT THE SCROLL EDGE, NO BACKGROUND OF ITS OWN — and that is still
        // solid. At the edge nothing has scrolled under the bar: what shows
        // through it is the screen's own background, which `pageBackground()`
        // makes the page. Measured, not assumed: an OPAQUE scroll-edge
        // appearance hid the large title outright on iOS 26 — «Земеделски
        // дневник» and «Задачи» rendered as an empty band in every arm,
        // while Борса, whose search field lives in the bar, kept its title.
        // A transparent one keeps the title on iOS 26 and is the system
        // default on iOS 17, where the scroll edge was never translucent.
        navigation.scrollEdgeAppearance = scrollEdgeAppearance()
        navigation.compactScrollEdgeAppearance = scrollEdgeAppearance()

        let tabs = UITabBar.appearance()
        tabs.standardAppearance = tabAppearance()
        tabs.scrollEdgeAppearance = tabAppearance()
    }

    private(set) static var isInstalled = false

    /// Once content scrolls under the bar: the page colour, opaque, with an
    /// `edge` hairline — so a title sits on the colour of the list it heads,
    /// and the rows passing beneath it cannot show through.
    static func navigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Palette.Surface.page)
        appearance.shadowColor = UIColor(Palette.Surface.edge)
        return appearance
    }

    /// At the scroll edge: no background, no blur, no line — the page
    /// beneath is the surface. See `install()` for why not opaque here.
    static func scrollEdgeAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        return appearance
    }

    /// `Surface.bar` with an `edge` hairline above it — the web's bottom tab
    /// bar, token for token. Unselected items are `secondaryText`, as on
    /// the web; selected keeps the app's tint, `accent`. Both are measured
    /// on `Surface.bar` in `PaletteTokenTests`.
    ///
    /// The system's unselected grey is not a token, and on the dark bar it
    /// was the one label in the bar nobody had measured.
    static func tabAppearance() -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Palette.Surface.bar)
        appearance.shadowColor = UIColor(Palette.Surface.edge)

        let normal = UIColor(Palette.secondaryText)
        let selected = UIColor(Palette.accent)
        for item in [appearance.stackedLayoutAppearance,
                     appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = normal
            item.normal.titleTextAttributes = [.foregroundColor: normal]
            item.selected.iconColor = selected
            item.selected.titleTextAttributes = [.foregroundColor: selected]
        }
        return appearance
    }
}
