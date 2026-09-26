import SwiftUI

/// The app's one menu, in the same place on every screen.
///
/// ── Why a menu and not more tabs ──
///
/// iOS gives five tab slots before it collapses the rest behind "More", and
/// all five are spent: Дневник, Калкулатор, Борса, Локации, Админ. The task
/// engine and the rest of the admin panel have nowhere to go. A menu is the
/// surface that does not have to be rationed.
///
/// ── Why it is on every tab, not only the first ──
///
/// Each tab owns its own `NavigationStack`, so a menu added to one is absent
/// from the other four. A control that moves depending on which tab you are
/// on is worse than no control: an operator learns where it is once and then
/// finds it missing. Same placement, same glyph, same contents, everywhere.
///
/// ── What it does NOT contain ──
///
/// Nothing speculative. The owner asked for the menu, not for a list of
/// things to put in it, and a menu padded with disabled rows for features
/// that do not exist reads as a broken app rather than a planned one. It
/// carries what is true today: who you are signed in as, and the way out.
/// Items get added when the screens behind them exist.
struct AppMenuButton<Extra: View>: View {
    @Environment(AuthClient.self) private var auth

    /// SCREEN-SPECIFIC ITEMS, above the global ones.
    ///
    /// The menu was deliberately "nothing speculative" — what is true today
    /// and no padding. A per-screen action is not padding: boundary import
    /// belongs to one location and nowhere else, and it is monthly work,
    /// which is exactly what this menu was described as being for.
    ///
    /// In its own `Section` so the two kinds never read as one list. A farmer
    /// scanning for «Изход» must not have to step over an action that only
    /// exists on this screen.
    @ViewBuilder var extra: Extra

    @State private var tabs = BottomTabsStore.shared
    @State private var showingAdmin = false

    /// Which overflow screen is open, if any. One piece of state rather
    /// than a Bool per surface — the set is now derived from what is NOT
    /// in the bottom row, so it changes at runtime and cannot have a
    /// fixed number of flags.
    @State private var presented: AppSurface?

    var body: some View {
        Menu {
            // Context, not an action. Which farm you are signed into is the
            // thing a menu is asked most often on a multi-tenant app, and
            // getting it wrong means filing a record against the wrong
            // holding — which for a regulatory diary is not a small mistake.
            if !(Extra.self == EmptyView.self) {
                Section { extra }
            }

            Section(Config.tenantSlug) {
                // EVERY surface not in the bottom row, always.
                //
                // This is what makes the tab customiser safe rather than a
                // trap. A farmer who takes Дневник out of the bar must
                // still be able to open the diary, and a preference
                // control that can strand a feature is not a setting. The
                // list is derived from the bar, so the two cannot drift.
                ForEach(tabs.overflow) { surface in
                    Button {
                        presented = surface
                    } label: {
                        Label(surface.label, systemImage: surface.icon)
                    }
                }

                Button {
                    showingAdmin = true
                } label: {
                    Label("Админ", systemImage: "person.2")
                }

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            // `line.3.horizontal` rather than the ellipsis iOS usually puts
            // in a toolbar: the owner asked for a hamburger, and it is also
            // the glyph the web app uses, so the two clients agree about
            // which corner holds "everything else".
            Label("Меню", systemImage: "line.3.horizontal")
        }
        // The glyph alone is not a name. VoiceOver would otherwise announce
        // "line 3 horizontal".
        .accessibilityLabel("Меню")
        .accessibilityHint("Отваря менюто на приложението")
        // A sheet, not a tab. Админ left the tab bar because it is a monthly
        // action; presenting it modally says the same thing — you came here
        // on purpose and you will go back.
        .sheet(isPresented: $showingAdmin) { AdminView() }
        // Each screen owns its own NavigationStack and Затвори button, the
        // same shape AdminView already uses — the menu presents, the screen
        // knows how to be presented.
        .sheet(item: $presented) { $0.screen }
    }
}

extension View {
    /// Put the app menu in the TRAILING slot of this screen's navigation bar.
    ///
    /// An extension rather than five copies of the same `.toolbar` block, so
    /// placement cannot drift between tabs — the drift is silent, because
    /// nobody opens all five in a row.
    ///
    /// Moved from leading to trailing on the owner's instruction. The
    /// bottom-row editor that used to sit in this slot has gone with it —
    /// it now lives inside Админ, where the other settings are, rather than
    /// riding along on every screen. That leaves one glyph in the bar
    /// instead of two, which is also what gives a Bulgarian title back the
    /// width it was losing.
    func appMenu() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { AppMenuButton(extra: { EmptyView() }) }
        }
    }

    /// The menu, plus items belonging to THIS screen.
    func appMenu<Extra: View>(@ViewBuilder extra: @escaping () -> Extra) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { AppMenuButton(extra: extra) }
        }
    }
}


/// The row inside Админ that opens the bottom-row editor.
///
/// This was a toolbar glyph on all five tab roots. It is a SETTING — which
/// screens are in the bottom bar — and settings belong where the other
/// settings are, not in the bar of every screen that has nothing to do
/// with them.
struct TabCustomiserRow: View {
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            LabeledContent {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    // The ONLY mark that this row opens something, and at
                    // `.tertiary` it measures 1.73:1 against a white row —
                    // invisible rather than subtle. A non-text control needs
                    // 3:1; `.secondary` is 3.44:1.
                    .foregroundStyle(.secondary)
            } label: {
                Label("Долна лента", systemImage: "square.grid.2x2")
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Избира кои екрани са в долната лента")
        .sheet(isPresented: $editing) { TabCustomiserView() }
    }
}
