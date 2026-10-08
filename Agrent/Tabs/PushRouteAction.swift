import SwiftUI

/// Push a route onto the stack this view is in (agrent-ios#194): for a push
/// that a tap doesn't start directly — after a request answers, or from a
/// control that must not be a `NavigationLink` (Риск's «История»).
///
/// Read as `@Environment(\.pushRoute)`; every `RoutedStack` sets it to append
/// to the path it holds, the router's or its own.
struct PushRouteAction {
    let push: @MainActor (AppRoute) -> Void

    @MainActor
    func callAsFunction(_ route: AppRoute) { push(route) }
}

extension EnvironmentValues {
    /// Set by every `RoutedStack`. Outside one there is no stack to push
    /// onto, and nothing happens.
    @Entry var pushRoute = PushRouteAction { _ in }
}
