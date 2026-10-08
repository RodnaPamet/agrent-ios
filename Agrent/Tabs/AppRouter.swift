import Observation
import SwiftUI

/// Which tab is selected, and what each tab on the bar has pushed
/// (agrent-ios#194, P4.5).
///
/// ── Owned by `MainTabView`, not shared ──
///
/// A path holds models from ONE farm. `FarmGate` rebuilds `MainTabView` for
/// each farm (`.id(farm.slug)`) and sign-out removes it, so a router that
/// lives there starts empty for every farm and every person by construction:
/// no listing from the last farm left on a stack, and no singleton for
/// `SessionReset` to have to remember.
///
/// ── A `NavigationPath`, not `[AppRoute]` ──
///
/// A stack that pushes values must push NOTHING else — SwiftUI's two ways of
/// pushing, a view inside the link and a value on the path, don't mix. So
/// every push inside a tab is a value, and not every value can be an
/// `AppRoute`: a parcel's history cards open lists that share the history
/// screen's own store, which nothing outside that screen should hold. The
/// type-erased path takes the screen's own value beside the app's routes.
@Observable
@MainActor
final class AppRouter {
    /// What each tab has pushed, innermost last. A tab with no entry is at
    /// its root.
    var paths: [AppSurface: NavigationPath] = [:]

    /// One tab's path, as `RoutedStack` binds it: empty when nothing is
    /// pushed, and back to no entry at all when the stack is popped to its
    /// root, so "no entry" keeps meaning "at the root".
    ///
    /// A subscript of its own because a binding can't reach
    /// `paths[surface, default: …]`: a key path's subscript arguments must be
    /// `Hashable`, and `default:` is a closure.
    subscript(path surface: AppSurface) -> NavigationPath {
        get { paths[surface] ?? NavigationPath() }
        set { paths[surface] = newValue.isEmpty ? nil : newValue }
    }

    /// The bar as last adopted, in order.
    private(set) var bar: [AppSurface]

    private var selected: AppSurface

    init(bar: [AppSurface]) {
        self.bar = bar
        selected = bar.first ?? AppSurface.fallback[0]
    }

    /// The selected tab, as `TabView(selection:)` reads and writes it.
    ///
    /// Choosing the tab that is ALREADY selected pops it to its root — what a
    /// re-tap does in every iOS app with tabs. `TabView` writes the selection
    /// on a re-tap as well, and that write is the only sign of the gesture
    /// (checked on a simulator's tab bar, 2026-10-08).
    var tab: AppSurface {
        get { selected }
        set {
            if newValue == selected { paths[newValue] = nil }
            selected = newValue
        }
    }

    /// The bar changed: the customiser, or `/me` bringing the saved order.
    func adoptBar(_ newBar: [AppSurface]) {
        bar = newBar
        // A tab that left the bar is drawn by the menu from now on, as a
        // sheet with a stack of its own. Its pushes kept here would reappear,
        // out of nowhere, the day it came back to the bar.
        paths = paths.filter { newBar.contains($0.key) }
        if !newBar.contains(selected), let first = newBar.first {
            selected = first
        }
    }

    /// Show `route`: the way in for a link (#206) or a notification (P7.7).
    ///
    /// On its own tab when that tab is on the bar, as the only screen pushed
    /// there. Otherwise on top of the tab the person is looking at — the
    /// menu's sheets keep stacks of their own, and every stack can show
    /// every route.
    func open(_ route: AppRoute) {
        if bar.contains(route.home) {
            selected = route.home
            paths[route.home] = NavigationPath([route])
        } else {
            self[path: selected].append(route)
        }
    }
}
