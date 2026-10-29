import SwiftUI

/// Light or dark, chosen in Админ (owner, 2026-10-29), or the phone's own.
///
/// AUTOMATIC BY DEFAULT: the app followed the phone until there was a
/// choice, and nobody should open it after an update to find it changed.
/// Stored on the device, not the account: two people sharing a phone see
/// it the same, and it outlives a sign-out like the phone's own setting.
///
/// «Слънце», the high-contrast palette, is not a third choice here: it is
/// what the phone's Increase Contrast switches on, in either theme.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark

    static let storageKey = "appearance.theme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Автоматично"
        case .light: "Светла"
        case .dark: "Тъмна"
        }
    }

    /// What the root asks of the window: nil is the phone's own.
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
