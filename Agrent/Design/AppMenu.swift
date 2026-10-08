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
/// carries what is true today: the screens that are not on the bottom bar,
/// and Админ in a section of its own. Items get added when the screens
/// behind them exist.
///
/// Nor the account (owner, 2026-10-07). «Профил» and «Изход» were rows here;
/// both now sit one level down, in Админ: its top row opens Профил, which
/// holds the app's only Изход. `AdminView` draws that row for every role and
/// in every state, which is what makes taking them out of here safe: a
/// reader whom Админ refuses still reaches Изход through it.
struct AppMenuButton<Extra: View>: View {
    /// SCREEN-SPECIFIC ITEMS, above the global ones.
    ///
    /// The menu was deliberately "nothing speculative" — what is true today
    /// and no padding. A per-screen action is not padding: boundary import
    /// belongs to one location and nowhere else, and it is monthly work,
    /// which is exactly what this menu was described as being for.
    ///
    /// In its own `Section` so the two kinds never read as one list. A farmer
    /// scanning for a screen must not have to step over an action that only
    /// exists on this one.
    @ViewBuilder var extra: Extra

    @State private var tabs = BottomTabsStore.shared
    @State private var unread = ExchangeUnreadStore.shared
    @State private var showingAdmin = false
    @State private var farms = FarmStore.shared

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

            // The open farm by NAME (#179) — a person can hold several now,
            // and the slug is a URL fragment rather than what anyone calls
            // their farm. The slug stands in until the name is known.
            Section(titled: farms.activeFarm.map { $0.name ?? $0.slug } ?? "") {
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
                        // Борса off the bar takes its unread badge with it,
                        // so the count rides on the row that opens it.
                        Label(
                            surface == .exchange
                                ? MessagingPolicy.counted(surface.label, unread: unread.count)
                                : surface.label,
                            systemImage: surface.icon
                        )
                    }
                }
            }

            // ITS OWN SECTION, last — where «Профил» and «Изход» sat before
            // they moved under it (owner, 2026-10-07). Админ is the way to the
            // account and to Изход now, for every role (see the type's
            // header), so it stands apart from the screens rather than
            // reading as one more of them.
            Section {
                Button {
                    showingAdmin = true
                } label: {
                    Label("Админ", systemImage: "person.2")
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
        // Each screen owns its own NavigationStack, the same shape AdminView
        // uses. The «Затвори» does NOT belong to the screen, though (#119):
        // every surface can be a tab root or a menu sheet depending on the
        // farmer's bar, and only this line knows which. The flag says so,
        // and `closeWhenPresentedFromMenu` — inside each stack, where a
        // toolbar item can reach the bar — draws the button from it.
        //
        // Per-screen buttons were how Борса ended up with none: the five
        // screens that START as tabs never needed one until the customiser
        // could move them, and the four that start here had one that did
        // nothing whenever they were moved onto the bar.
        //
        // And no `routedSurface` (#194): this menu sits on a tab, so the
        // sheet would inherit that tab's surface and push onto ITS path.
        .sheet(item: $presented) {
            $0.screen
                .environment(\.presentedFromMenu, true)
                .environment(\.routedSurface, nil)
        }
    }
}

extension View {
    /// Put the app menu in the TRAILING slot of this screen's navigation bar.
    ///
    /// An extension rather than five copies of the same `.toolbar` block, so
    /// placement cannot drift between tabs — the drift is silent, because
    /// nobody opens all five in a row.
    ///
    /// LEADING, on the owner's instruction (2026-10-01). It was leading
    /// first, moved to trailing in #68, and went back. The bottom-row editor that used to sit in this slot has gone with it —
    /// it now lives inside Админ, where the other settings are, rather than
    /// riding along on every screen. That leaves one glyph in the bar
    /// instead of two, which is also what gives a Bulgarian title back the
    /// width it was losing.
    ///
    /// Also the way out when the menu presented this screen — every surface
    /// with a menu is one that can be moved off the bar, so the two travel
    /// together and a new surface cannot get one without the other.
    func appMenu() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { AppMenuButton(extra: { EmptyView() }) }
        }
        .closeWhenPresentedFromMenu()
    }

    /// The menu, plus items belonging to THIS screen.
    func appMenu<Extra: View>(@ViewBuilder extra: @escaping () -> Extra) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { AppMenuButton(extra: extra) }
        }
        .closeWhenPresentedFromMenu()
    }

    /// «Затвори» in the leading slot, when — and only when — the app menu
    /// presented this screen as a sheet.
    ///
    /// Apply it INSIDE the screen's `NavigationStack`: a toolbar item
    /// outside the stack has no bar to go in, which is why the presentation
    /// site sets a flag rather than adding the button itself. `.appMenu()`
    /// already applies it; the surfaces with no menu (Тенденции, Новини,
    /// Риск) call it directly.
    func closeWhenPresentedFromMenu() -> some View {
        modifier(MenuSheetClose())
    }
}

extension EnvironmentValues {
    /// Set by `AppMenuButton`'s sheet and by nothing else. FALSE BY DEFAULT
    /// is the half that matters for tab roots: `MainTabView` sets nothing, so
    /// a surface on the bar draws no «Затвори» — a button there would call
    /// `dismiss()` on a screen nothing presented, and do nothing.
    @Entry var presentedFromMenu = false
}

/// The #108 defect class, closed at the one place that knows.
///
/// A menu sheet with no «Затвори» cannot reliably be left: most surfaces are
/// full-height `List`s or `ScrollView`s, so a downward drag scrolls the
/// content and never reaches the sheet. #108 found that on Табло, #119 on
/// Борса — where the inbox's conversations are pushed inside the same sheet,
/// so they inherited it (their back button leads here, and now here has a
/// way out).
///
/// `dismiss` is read at the root the modifier is applied to, so it closes
/// the sheet rather than popping a pushed screen.
private struct MenuSheetClose: ViewModifier {
    @Environment(\.presentedFromMenu) private var presentedFromMenu
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            if presentedFromMenu {
                // TRAILING, not `.cancellationAction`. In a sheet the system
                // puts a cancellation action on the LEADING edge — where the
                // menu glyph now sits — and two controls stacked in one corner
                // read as one. The opposite corner keeps them apart.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Затвори") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.close)
                }
            }
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
            ValueRow {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    // The ONLY mark that this row opens something, and at
                    // `.tertiary` it measured 1.73:1 against a white row —
                    // invisible rather than subtle. A non-text control needs
                    // 3:1; `Palette.secondaryText` is 6.86:1.
                    .foregroundStyle(Palette.secondaryText)
            } label: {
                Label("Долна лента", systemImage: "square.grid.2x2")
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Избира кои екрани са в долната лента")
        .sheet(isPresented: $editing) { TabCustomiserView() }
    }
}
