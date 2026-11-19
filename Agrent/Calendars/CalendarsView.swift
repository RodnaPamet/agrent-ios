import SwiftUI

/// «Календари» (#633, owner 2026-11-15): the agronomic calendar and the
/// lunar one, side by side, in one stack.
struct CalendarsView: View {
    @State private var flags = FeatureFlags.shared
    @Environment(\.dismiss) private var dismiss

    enum Page: Hashable { case agro, lunar }

    var body: some View {
        RoutedStack {
            List {
                NavigationLink(value: Page.agro) {
                    Label(AgroWords.title, systemImage: "leaf")
                }
                .accessibilityInputLabels(A11y.spokenNames("Агрономически календар", "Агрономически", "Agronomic calendar"))
                .pageRow()
                if flags.isOn(LunarAPI.flag) {
                    NavigationLink(value: Page.lunar) {
                        Label(LunarWords.title, systemImage: "moon.stars")
                    }
                    .accessibilityInputLabels(A11y.spokenNames("Лунен календар", "Луна", "Lunar calendar"))
                    .pageRow()
                }
            }
            .pageBackground()
            .inlineTitle(AgroWords.calendars)
            .navigationDestination(for: Page.self) { page in
                Group {
                    switch page {
                    case .agro: AgroCalendarView()
                    case .lunar: LunarCalendarView()
                    }
                }
                .floatingBack()
            }
            .floatingClose { dismiss() }
        }
    }
}
