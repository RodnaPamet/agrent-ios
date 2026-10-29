import SwiftUI

/// «Тема» in Админ (owner, 2026-10-29): light, dark, or the phone's own.
///
/// For every role, a reader included, so it sits above the part of Админ a
/// reader is refused. The choice is the device's (`AppTheme`), and the root
/// applies it to every screen and sheet at once.
struct ThemeRow: View {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Written above, as a segmented picker shows no title of its
            // own; VoiceOver hears it from the picker's own name.
            Text("Тема")
                .accessibilityHidden(true)
            Picker("Тема", selection: $theme) {
                ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Тема")
            .accessibilityInputLabels(A11y.spokenNames("Тема", "Theme"))
        }
        .padding(.vertical, 4)
    }
}
