import SwiftUI
import UIKit

/// The dark theme's ground, applied once rather than screen by screen.
///
/// SwiftUI's `List` is UIKit underneath, and its background comes from the
/// system grouped colour rather than from anything a SwiftUI modifier on the
/// row sets. Overriding it per screen means `.scrollContentBackground(.hidden)`
/// plus a background on each of a dozen views, and the one somebody forgets
/// is a white rectangle in the middle of a dark green app.
///
/// So it is installed once, on the appearance proxies, beside
/// `BulgarianLayout` and for the same reason: a process-wide fact belongs at
/// a process-wide seam.
///
/// LIGHT IS UNCHANGED. Every colour here is `Color(light:dark:)` whose light
/// value is what the app already drew, so this adds an appearance rather than
/// replacing one. The web's light palette is a genuinely different palette
/// and this app's light mode was not asked about.
enum Appearance {

    @MainActor
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let page = UIColor(Palette.Surface.page)
        let card = UIColor(Palette.Surface.card)

        // Lists and the plain scroll views behind them.
        UICollectionView.appearance().backgroundColor = page
        UITableView.appearance().backgroundColor = page
        UITableViewCell.appearance().backgroundColor = card

        // The bars. Without this the navigation bar keeps the system's
        // grey material over a green page, which reads as a seam rather
        // than a bar.
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = page
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = page
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    @MainActor
    private(set) static var isInstalled = false

    /// Tests only — `install()` is once per process by design.
    @MainActor
    static func resetForTesting() { isInstalled = false }
}

extension View {
    /// The page ground, on a screen that scrolls.
    ///
    /// `UICollectionView.appearance()` does NOT reach a SwiftUI `List` on
    /// current iOS — the bars took the green and the list stayed black, on
    /// screen, which is how this was found. `scrollContentBackground(.hidden)`
    /// is the supported way to say the scroll view should not draw the
    /// system's, and the background behind it is then ours.
    ///
    /// Applied per screen rather than once, because there is no single view
    /// every list descends from — `MainTabView` builds each tab's root from
    /// a stored order, and a background there sits behind the tab content
    /// rather than inside each scrollable.
    func pageBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.Surface.page)
    }
}
