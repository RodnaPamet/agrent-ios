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
struct AppMenuButton: View {
    @Environment(AuthClient.self) private var auth

    @State private var showingAdmin = false

    var body: some View {
        Menu {
            // Context, not an action. Which farm you are signed into is the
            // thing a menu is asked most often on a multi-tenant app, and
            // getting it wrong means filing a record against the wrong
            // holding — which for a regulatory diary is not a small mistake.
            Section(Config.tenantSlug) {
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
    }
}

extension View {
    /// Put the app menu in the leading slot of this screen's navigation bar.
    ///
    /// An extension rather than five copies of the same `.toolbar` block, so
    /// placement cannot drift between tabs — the drift is silent, because
    /// nobody opens all five in a row.
    func appMenu() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { AppMenuButton() }
        }
    }
}
