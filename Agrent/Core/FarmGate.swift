import SwiftUI

/// The tabs, once a farm is open — and what to say when none can be
/// (agrent-ios#179).
///
/// A returning farmer passes straight through: `FarmStore` restores their
/// farm before the first frame, with no request. Only a person with nothing
/// remembered on this phone ever sees the other states, and each has a way to
/// Профил — the app's only Изход (#174) — because none of them has the menu.
struct FarmGate: View {
    @State private var farms = FarmStore.shared
    @State private var me = CurrentUserStore.shared
    @State private var flags = FeatureFlags.shared

    var body: some View {
        Group {
            switch farms.state {
            case .active(let farm):
                // A NEW IDENTITY PER FARM. Every screen builds its own store
                // in `@State`, and SwiftUI keeps state for as long as a view
                // keeps its identity — so without this, a farm switch would
                // leave each tab showing the previous farm's records until
                // something reloaded it. Keyed on the slug: renaming a farm
                // is not a reason to rebuild everything.
                MainTabView().id(farm.slug)
            case .resolving:
                ProgressView("Зареждане на стопанството…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.Surface.page)
            case .none:
                OutsideAFarm {
                    // Creating one, when the server offers it to this person —
                    // `/me` has just been read, so the flags are this
                    // person's. Absent means off, and then only the way an
                    // existing farm can let them in.
                    if flags.isOn(FarmWizardText.flag) {
                        FarmWizardView(context: .onboarding) { farms.activate($0) }
                    } else {
                        EmptyState(
                            Self.noFarmTitle,
                            icon: "building.2",
                            message: Self.noFarmMessage
                        )
                    }
                }
            case .failed:
                OutsideAFarm {
                    ErrorState(message: Self.unavailable) { await farms.resolve() }
                }
            }
        }
        .task { await farms.resolve() }
        // The menu names the farm; `/me` can name the one seeded by slug.
        .onChange(of: me.user?.tenant) { _, tenant in farms.adoptName(from: tenant) }
    }

    static let noFarmTitle = "Нямате стопанство"
    /// Only while creating a farm is switched off for this person — with it
    /// on, the wizard is this screen.
    static let noFarmMessage = "Профилът Ви все още не е свързан със стопанство. "
        + "Помолете собственика на стопанството да Ви покани."
    static let unavailable = "Стопанството не може да бъде заредено. Проверете връзката и опитайте пак."
}

/// A state with no farm in it: the page, and Профил in the corner — the way
/// to Изход when the tabs and their menu are not there.
private struct OutsideAFarm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .pageBackground()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ProfileView()
                        } label: {
                            Label("Профил", systemImage: "person.crop.circle")
                        }
                        .accessibilityInputLabels(A11y.Spoken.profile)
                    }
                }
        }
    }
}
