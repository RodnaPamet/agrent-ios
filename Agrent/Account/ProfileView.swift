import SwiftUI

/// «Профил» — who is signed in, and the way out. For EVERY role (owner,
/// 2026-10-06, agri-saas#1193 P2.8), not only the admins Админ serves.
///
/// ── Reached from Админ, and only from there (owner, 2026-10-07) ──
///
/// The app menu had «Профил» and «Изход» rows of its own; the owner took both
/// out. Админ's top row opens this page for every role — the readers Админ
/// refuses included, for whom it is now the only way out — so `AdminView`
/// draws that row in every state. Pushed inside Админ's stack, so the page has
/// a back button and needs no «Затвори».
///
/// ── The web's `/account`, cut to what a phone can back ──
///
/// The web's account area (P2.7) is a header — «Вашият акаунт» and the email
/// — over two sections, «Профил» (picture upload, name editing, sound and
/// haptics) and «Сигурност» (password). Nothing of it is tenant-scoped, which
/// is why it works with zero farms; this page reads nothing tenant-scoped
/// either — `/api/auth/me` has no slug in its path.
///
/// What this page shows is what `/me` already sends: the picture (or the
/// initials), the name, the email. The web's edits are NOT here: `PATCH
/// /api/account/profile` and `POST`/`DELETE /api/account/avatar` exist as
/// route code but are not in openapi.json, and this app builds against the
/// spec (owner: no editing until the API is documented). The password form is
/// for credential accounts; this app signs in through the browser.
///
/// ── The same card as Админ, not a second copy ──
///
/// `AccountCard` is the one component. Админ shows it at its top as a link
/// to here; this page shows it unlinked, because this IS where it leads. Two
/// renderings of "who is signed in" would drift — the initials rule and the
/// spoken sentence are exactly the kind of thing one copy gets fixed in.
///
/// ── The app's only Изход ──
///
/// Behind `SignOutConfirmation`, the one question any Изход asks.
struct ProfileView: View {
    /// The shared instance, held as `@State` the way `AdminView` holds it, so
    /// the card appears when `/me` resolves while this page is open.
    @State private var me = CurrentUserStore.shared
    /// Whether the one `load()` this page asks for has come back empty —
    /// what separates "still asking" from "could not find out".
    @State private var identityUnavailable = false
    @State private var confirmingSignOut = false
    @State private var flags = FeatureFlags.shared
    @State private var addingFarm = false

    var body: some View {
        List {
            Section { identity }.pageRow()

            // A person's farms are the person's, not one farm's — so Профил,
            // not Админ (owner, 2026-10-08, agrent-ios#179). Offered only when
            // the server offers it to this person: `POST /api/me/farms`
            // follows the same flag, and an absent flag is off.
            if flags.isOn(FarmWizardText.flag) {
                Section {
                    Button {
                        addingFarm = true
                    } label: {
                        Label(FarmWizardText.addTitle, systemImage: "plus.circle")
                    }
                    .accessibilityInputLabels(A11y.spokenNames(FarmWizardText.addTitle, "Add farm"))
                }
                .pageRow()
            }

            // Its own section, so the destructive row never reads as one more
            // fact about the account. ALWAYS drawn — a page that cannot say
            // who you are must still let you leave, and an offline launch with
            // no cached `/me` is exactly when a person might want to.
            Section {
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityInputLabels(A11y.Spoken.signOut)
                // On the row that asks, not on the List: the dialog animates
                // from its trigger (and on iPad points at it).
                .signOutConfirmation(isPresented: $confirmingSignOut)
            }
            .pageRow()
        }
        .pageBackground()
        .inlineTitle("Профил")
        // Its own stack: a sheet over Профил, wherever Профил was opened.
        // Opening the new farm rebuilds the tabs for it (`FarmGate`), which
        // takes this sheet and the screens under it away with the old farm.
        .sheet(isPresented: $addingFarm) {
            NavigationStack {
                FarmWizardView(context: .adding) { FarmStore.shared.activate($0) }
            }
        }
        // The launch already asked; this returns that answer without a request
        // when there is one, and asks again (cache first) when the launch got
        // nothing — the case where this page would otherwise spin forever.
        .task {
            if await me.load() == nil { identityUnavailable = true }
        }
    }

    @ViewBuilder
    private var identity: some View {
        if let user = me.user {
            AccountCard(user: user)
        } else if identityUnavailable {
            Label(Self.unavailable, systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(Palette.secondaryText)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Зареждане на профила")
        }
    }

    /// No network and no cached `/me`. Not `Palette.error`: the account is
    /// fine, this phone just cannot say whose it is right now.
    static let unavailable = "Профилът не може да бъде зареден в момента."
}
