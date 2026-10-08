import SwiftUI

/// The `NavigationStack` of every screen that can sit on the bar
/// (agrent-ios#194, P4.5). Each `AppSurface` root uses this in place of a
/// bare `NavigationStack`; `RoutedStackTests` fails a root that doesn't.
///
/// ── Two homes for the path ──
///
/// ON THE BAR, the path is the router's, under the tab's surface: a re-tap
/// pops it and `AppRouter.open(_:)` can fill it.
///
/// AS A MENU SHEET, or anywhere else with no surface set, the stack keeps a
/// path of its own — fresh with every presentation, exactly as before the
/// router. A sheet sharing the router's path would open on whatever was
/// pushed the last time it was shown.
///
/// ── Values only ──
///
/// Everything pushed inside is a value on that path: a `NavigationLink(value:)`
/// or `pushRoute`. Never a view inside a link, and never
/// `navigationDestination(item:)` — SwiftUI does not mix the two ways of
/// pushing in one stack, and `RoutedStackTests` holds the app to it.
struct RoutedStack<Root: View>: View {
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.routedSurface) private var surface
    @State private var ownPath = NavigationPath()
    @ViewBuilder var root: Root

    var body: some View {
        if let router, let surface {
            @Bindable var router = router
            NavigationStack(path: $router[path: surface]) { routed }
                .environment(\.pushRoute, PushRouteAction { router[path: surface].append($0) })
        } else {
            NavigationStack(path: $ownPath) { routed }
                .environment(\.pushRoute, PushRouteAction { ownPath.append($0) })
        }
    }

    /// Registered ONCE, at the root. A second registration for `AppRoute`
    /// further up the stack would be ignored, with a runtime warning.
    private var routed: some View {
        root.navigationDestination(for: AppRoute.self) { $0.destination }
    }
}

extension EnvironmentValues {
    /// The bar tab whose root this is. Set by `MainTabView` alone, and set
    /// back to nil by the menu's sheet: a tab's own menu presents it, so the
    /// sheet would otherwise inherit that tab's surface — and its path.
    @Entry var routedSurface: AppSurface? = nil
}
