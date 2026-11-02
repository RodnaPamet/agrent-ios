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
/// initials), the name, the email. The picture can be changed or removed
/// here (`AccountPictureRows`, #333): `POST`/`DELETE /api/account/avatar` are
/// documented since agri-saas #1900, and the server takes the JPEG a phone
/// can make since #1951. The name can't: `PATCH /api/account/profile` is
/// still not in openapi.json, and this app builds against the spec (owner:
/// no editing until the API is documented). The password form is for
/// credential accounts; this app signs in through the browser.
///
/// ── The same card as Админ, not a second copy ──
///
/// `AccountCard` is the one component. Админ shows it at its top as a link
/// to here; this page shows it unlinked, because this IS where it leads. Two
/// renderings of "who is signed in" would drift — the initials rule and the
/// spoken sentence are exactly the kind of thing one copy gets fixed in.
///
/// ── The person's farms (agrent-ios#179, stage 3) ──
///
/// Every farm this person belongs to, from `GET /api/me/farms`, with their
/// role in each and a tick on the open one; choosing another opens it, and
/// `FarmGate` rebuilds the tabs for it — which takes this page away with the
/// old farm, as creating a farm does. The list is UNGATED: a person reaches
/// the farms they already belong to whatever `social.farm-registration`
/// says, and only «Добави стопанство» follows that flag.
///
/// Not tenant-scoped either: `/api/me/farms` has no slug in its path, and
/// `FarmStore` reads it.
///
/// ── The app's only Изход ──
///
/// Behind `SignOutConfirmation`, the one question any Изход asks.
///
/// ── And «Изтрий профила» ──
///
/// Below it, to `DeleteAccountView` (agrent-ios#281).
struct ProfileView: View {
    /// The shared instance, held as `@State` the way `AdminView` holds it, so
    /// the card appears when `/me` resolves while this page is open.
    @State private var me = CurrentUserStore.shared
    /// Whether the one `load()` this page asks for has come back empty —
    /// what separates "still asking" from "could not find out".
    @State private var identityUnavailable = false
    @State private var confirmingSignOut = false
    @State private var flags = FeatureFlags.shared
    @State private var farms = FarmStore.shared
    @State private var addingFarm = false
    @State private var permission = PushPermission.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                identity
                if let user = me.user {
                    AccountPictureRows(user: user)
                }
            } footer: {
                SectionFooter {
                    if me.user != nil { Text(AccountPicture.note) }
                }
            }
            .pageRow()

            // A person's farms are the person's, not one farm's — so Профил,
            // not Админ (owner, 2026-10-08, agrent-ios#179).
            if showsFarms {
                Section {
                    ForEach(farmRows, id: \.slug) { farm in
                        let isOpen = farm.slug == farms.activeFarm?.slug
                        FarmRow(farm: farm, isOpen: isOpen) {
                            if !isOpen { farms.open(farm) }
                        }
                    }
                    // Offered only when the server offers it to this person:
                    // `POST /api/me/farms` follows the same flag, and an
                    // absent flag is off. The list above does not.
                    if canAddFarm {
                        Button {
                            addingFarm = true
                        } label: {
                            Label(FarmWizardText.addTitle, systemImage: "plus.circle")
                        }
                        .accessibilityInputLabels(A11y.spokenNames(FarmWizardText.addTitle, "Add farm"))
                    }
                } header: {
                    SectionHeader(Self.farmsTitle)
                } footer: {
                    SectionFooter {
                        if farms.farms == nil, farms.listUnavailable {
                            Text(Self.farmsUnavailable)
                        }
                    }
                }
                .pageRow()
            }

            // Notifications on this phone, for this person (owner,
            // 2026-10-14, #272) — the same choice as the card in «Задачи»,
            // for whoever closed it or changes their mind.
            Section {
                Toggle(isOn: notificationsOn) {
                    Label(PushText.switchTitle, systemImage: "bell")
                }
                // iOS will not ask again after a no, so the switch cannot
                // turn this on; the button below says where it can be.
                .disabled(permission.standing == .refused)
                .accessibilityInputLabels(A11y.spokenNames(PushText.switchTitle, "Notifications"))
                if permission.standing == .refused {
                    Button(PushText.openSettings) { permission.openSystemSettings() }
                        .accessibilityInputLabels(A11y.spokenNames(PushText.openSettings, "Open Settings"))
                }
            } footer: {
                SectionFooter {
                    Text(permission.standing == .refused ? PushText.refusedNote : PushText.switchOnNote)
                }
            }
            .pageRow()

            // What the assistant has learned about this person, across farms
            // (#507, owner 2026-11-01: "see and delete"). Here and not on a
            // farm's page, because it is the person's, as the account is.
            // Both switches: the memory routes answer 404 while
            // `assistant.memory` is off, whatever the assistant's own flag.
            if flags.isOn(AssistantAPI.flag), flags.isOn(AssistantMemoryAPI.flag) {
                Section {
                    NavigationLink {
                        AssistantMemoryView()
                    } label: {
                        Label(AssistantMemoryText.title, systemImage: "brain")
                    }
                    .accessibilityInputLabels(A11y.spokenNames(AssistantMemoryText.title, "Assistant memory"))
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
                    // `destructive`'s ink over the role's system red, which
                    // is ~3.2:1 on the light page — and the same red as the
                    // «Изтрий профила» row below, not a second one.
                    Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Palette.destructive)
                }
                .accessibilityInputLabels(A11y.Spoken.signOut)
                // On the row that asks, not on the List: the dialog animates
                // from its trigger (and on iPad points at it).
                .signOutConfirmation(isPresented: $confirmingSignOut)
            }
            .pageRow()

            // Deleting the account, in the app (App Store 5.1.1(v),
            // agrent-ios#281). Below Изход and on a page of its own: what it
            // does is said before the one question is asked.
            Section {
                NavigationLink {
                    DeleteAccountView()
                } label: {
                    Label(AccountDeletionText.action, systemImage: "trash")
                        .foregroundStyle(Palette.destructive)
                }
                .accessibilityInputLabels(A11y.Spoken.deleteAccount)
            }
            .pageRow()

            // Which build this is, last, as iOS's own About puts it
            // (agrent-ios#393): an update installed while the next build was
            // still processing at Apple looked like a fix that hadn't worked.
            // Selectable, so it can go into a report as it reads.
            if let version = AppVersion.current {
                Section {
                    ValueRow {
                        Text(version).textSelection(.enabled)
                    } label: {
                        Text("Версия")
                    }
                }
                .pageRow()
            }
        }
        .pageBackground()
        .inlineTitle("Профил")
        .onAppear { UsageEvents.shared.screen(.profile) }
        // Its own stack: a sheet over Профил, wherever Профил was opened.
        // Opening the new farm rebuilds the tabs for it (`FarmGate`), which
        // takes this sheet and the screens under it away with the old farm.
        .sheet(isPresented: $addingFarm) {
            NavigationStack {
                FarmWizardView(context: .adding) { farms.openCreated($0) }
            }
        }
        // The launch already asked; this returns that answer without a request
        // when there is one, and asks again (cache first) when the launch got
        // nothing — the case where this page would otherwise spin forever.
        .task {
            if await me.load() == nil { identityUnavailable = true }
        }
        // Read again whenever the page opens — alongside `/me`, not after it:
        // a farm someone was added to on the web an hour ago belongs here now.
        .task { await farms.refreshFarms() }
        // Where iOS stands — again on a return, as the person may have just
        // been to Settings.
        .task { await permission.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await permission.refresh() } }
        }
    }

    /// The switch, onto `PushPermission`: what it shows is where iOS and the
    /// person stand, and a change is work — the iOS prompt, or removing this
    /// phone from the person's farms — rather than a value to store.
    private var notificationsOn: Binding<Bool> {
        Binding(
            get: { permission.isOn },
            set: { on in
                if on { Task { await permission.turnOn() } } else { permission.turnOff() }
            }
        )
    }

    /// The list once it has been read; until then the open farm alone, so
    /// this page never says less than the menu above it does.
    private var farmRows: [Farm] {
        farms.farms ?? farms.activeFarm.map { [$0] } ?? []
    }

    private var canAddFarm: Bool { flags.isOn(FarmWizardText.flag) }

    /// Nothing to list, nothing to add and nothing to say is no section.
    private var showsFarms: Bool {
        !farmRows.isEmpty || canAddFarm || farms.listUnavailable
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

    static let farmsTitle = "Стопанства"

    /// Under the open farm, which can still be shown: it is remembered.
    static let farmsUnavailable = "Списъкът със стопанствата Ви не може да бъде зареден в момента."

    /// A role in Bulgarian, from `MembershipRole` — the server's own
    /// vocabulary, verbatim. A role this build does not know shows nothing
    /// rather than an English token on a Bulgarian page.
    static func roleLabel(_ role: String?) -> String? {
        guard let role, let known = MembershipRole(rawValue: role), known != .unknown else { return nil }
        return known.label
    }
}

/// One of the person's farms: its name, their role there, and a tick on the
/// open one. The picker page's row (`FormChrome`), so choosing a farm reads
/// like every other choice in the app.
private struct FarmRow: View {
    let farm: Farm
    let isOpen: Bool
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The tick beside the name, and UNDER it at accessibility sizes: at
        // AX5 a tick beside «Синтетично» left the word too little width and it
        // broke in the middle (A11yShots, 16-profile). Decided from the size
        // and through `AnyLayout`, as `MetaRow` is, so the row re-lays out
        // rather than being rebuilt when the size changes.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        Button(action: open) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(farm.name ?? farm.slug)
                        .fixedSize(horizontal: false, vertical: true)
                    if let role = ProfileView.roleLabel(farm.role) {
                        Text(role)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOpen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The NAME is the label and the role its value. Left to itself the
        // button's label would be both texts, «Второ стопанство, Механизатор»,
        // and Voice Control answers to the whole label — so «Tap Второ
        // стопанство» could miss. VoiceOver still says both. No input label:
        // a farm's name is DATA, and this way the visible name is the name.
        .accessibilityLabel(farm.name ?? farm.slug)
        .accessibilityValue(ProfileView.roleLabel(farm.role) ?? "")
        // The tick is hidden; this is what it says.
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        // What a choice does here is bigger than a picker's: everything on
        // screen becomes the other farm's.
        .accessibilityHint(isOpen ? "" : Self.opensHint)
    }

    static let opensHint = "Отваря стопанството."
}
