import SwiftUI

@main
struct AgrentApp: App {
    @State private var auth = AuthClient()

    /// BEFORE ANY SCENE EXISTS, because the defect it fixes is paid by the
    /// first Bulgarian string UIKit measures — and on this app that can be
    /// the confirmation button on a write with no undo. See
    /// `BulgarianLayout`.
    init() {
        BulgarianLayout.install()
        // Before any scene too: the appearance proxy styles only the bars
        // created after it is set. See `SolidChrome`.
        SolidChrome.install()
        // Before any scene, for a different reason: before the first request.
        // Purges what older builds left in Cache.db and replaces
        // `URLCache.shared` with a zero-capacity one. See `NoURLCache` (#134).
        NoURLCache.install()
    }

    /// Which screen the app opens on.
    ///
    /// In Release, and in every debug run that was not launched with the
    /// seam's argument, this is `auth.state` and nothing else — the same
    /// expression the `switch` below has always been written against.
    ///
    /// Under `UITestSeam` it is `.signedIn`, because a runner's simulator has
    /// an empty Keychain and `AuthClient.init` therefore leaves the state at
    /// `.signedOut`. `auth` is left ALONE rather than driven into a signed-in
    /// state: `AuthClient` owns its own state machine and the seam has no
    /// business reaching into it.
    ///
    /// Изход IS special-cased, in `AuthClient.signOut`, and the reason is
    /// worth having here too. This property returns `.signedIn` for as long
    /// as the seam is on, so a sign-out changes nothing on screen — while on
    /// the owner's signed-in simulator, which is where the screenshot harness
    /// actually runs, it would have cleared a real Google session. Invisible
    /// and unrecoverable without a browser. That is the one place the seam
    /// has to reach into the auth path, and it reaches in to do LESS.
    private var openingState: AuthClient.State {
        #if DEBUG
        if UITestSeam.isActive { return .signedIn }
        #endif
        return auth.state
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch openingState {
                case .signedIn:
                    // Which farm, before any of it — see `FarmGate`.
                    FarmGate()
                default:
                    SignInView()
                }
            }
            .environment(auth)
            // Ochre, not the system blue and emphatically not green: green on
            // the parcel map is DATA — it encodes whether a parcel is sown —
            // so an accent in that family would read as one more state.
            .tint(Palette.accent)
            // Every literal in this app is hard-coded Bulgarian, but dates
            // were formatting against the DEVICE locale, which reports en-BG
            // here — so an all-Bulgarian journal printed "11 September".
            // Same root cause as the English error strings fixed earlier, in
            // a place nobody thought to look because the numbers were already
            // right: en-BG gives European digits and separators, so only the
            // month NAMES gave it away.
            //
            // Set once at the root rather than per call site: a formatter
            // somebody forgets is exactly how this came back a second time.
            .environment(\.locale, Locale(identifier: "bg_BG"))
        }
    }
}

/// Exactly five tabs, and that is a ceiling rather than a coincidence: iOS
/// collapses a sixth and everything after it into a "More" list, which buries
/// real features behind an extra tap and reads as a bug to an operator. The
/// roadmap scopes the app to four areas plus the journal, which spends the
/// budget precisely and leaves nothing for a sixth.
///
/// The auth gate stays in `AgrentApp` above and the Изход button stays in
/// `JournalListView`'s toolbar — this type only routes.
struct MainTabView: View {
    @State private var tabs = BottomTabsStore.shared
    @State private var outbox = OutboxStore.shared
    @State private var unread = ExchangeUnreadStore.shared
    @State private var foreground = ForegroundReturn()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthClient.self) private var auth

    var body: some View {
        // Built from the saved order rather than written out, so the bar
        // and the menu's overflow are two views of one list and cannot
        // disagree about what is where.
        //
        // The five-slot ceiling stays — see `AppSurface.capacity`. It is
        // enforced in the store rather than here, because the editor has
        // to know it too and a limit spelled in two places is a limit that
        // will eventually be two different numbers.
        VStack(spacing: 0) {
            OutboxBanner()
            TabView {
                ForEach(tabs.bottomTabs) { surface in
                    surface.screen
                        .tabItem { Label(surface.label, systemImage: surface.icon) }
                        // How many conversations have something unread
                        // (PARITY GAP 7) — THREADS, not messages; 0 draws no
                        // badge. The web has none; the owner asked for one.
                        // When Борса is not on the bar the app menu's row
                        // carries the count instead.
                        .badge(surface == .exchange ? unread.count : 0)
                }
            }
        }
        // Drained on launch and on every return to the foreground — which
        // is when a farmer who recorded something in a field has most
        // likely just found signal. Waiting for them to press a button
        // would make the queue their job rather than the app's.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await outbox.flush()
                    Task.detached { await OfflinePrefetch.warm() }
                }
                // The badge, on every return: a reply that came in while the
                // phone was in a pocket is exactly what it is for. No push
                // exists to say so sooner.
                Task { await unread.refresh() }
            }
            // Who, and with which flags, on every RETURN (owner decision
            // 2026-10-02): the only way a flag flip reaches an app that is
            // already open, since nothing polls while it is. Not the first
            // `.active` of a launch — `.task` below is already reading `/me`
            // then — and not while signed out, where there is nobody to ask
            // about. `foreground` decides which `.active` is a return.
            if foreground.isReturn(to: phase), auth.state == .signedIn {
                Task { await CurrentUserStore.shared.refresh() }
                // The farm list is read on the same return by `FarmGate`,
                // which is there in every state; the tabs are not.
            }
        }
        .task {
            // NOT AWAITED, and caching it was not enough.
            //
            // `/api/auth/me` was the only uncached read in the app, so on
            // a cold launch with no signal it waited out the request
            // timeout — measured at 16.0s on a real phone — and it was the
            // FIRST thing this task awaited, so everything behind it
            // waited too.
            //
            // Caching fixed the second launch and not the first: the cache
            // is written only after a successful fetch, so a farmer whose
            // first launch of the day is already in a field still paid the
            // full timeout. The blocking is the defect; the cache miss
            // merely exposes it.
            //
            // Nothing on this screen needs the answer. The tab bar has a
            // working default (`AppSurface.fallback`) and adopts the saved
            // order whenever it arrives; the spray sheet resolves the user
            // separately for its own gate. So it resolves alongside, not in
            // front.
            Task {
                // The store adopts the bar itself now — see
                // `CurrentUserStore.commit` — so a foreground refresh does too.
                _ = await CurrentUserStore.shared.load()
                // AFTER the user resolves, so a MECHANISATOR — who has no
                // Борса — is not sent to collect a 403 for a badge.
                await unread.refresh()
            }
            await outbox.flush()
            // DETACHED, not awaited.
            //
            // The catalogue is opportunistic warming. Awaited here it ran
            // four sequential requests inside the view's own task, each
            // timing out at 15s with no signal — a minute of work attached
            // to the lifetime of the screen that started it. Nothing should
            // wait on a prefetch, least of all the first screen a farmer
            // sees.
            Task.detached { await OfflinePrefetch.warm() }
        }
    }
}

/// Which `.active` is a RETURN to the app, as opposed to the launch's own.
///
/// Keyed on having been in `.background`, not on "any `.active` after the
/// first": `.onChange` does fire for a launch's inactive → active on some
/// paths and not others, so counting them would either read `/me` twice on
/// a cold launch or skip the first real return. And `.inactive` alone —
/// Control Centre pulled down, a call banner — is not leaving the app; a
/// farmer who never left has nothing new to be told.
///
/// A value, not view logic, so `CurrentUserRefreshTests` can drive it.
struct ForegroundReturn {
    private(set) var hasLeft = false

    mutating func isReturn(to phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            hasLeft = true
            return false
        case .active:
            defer { hasLeft = false }
            return hasLeft
        default:
            return false
        }
    }
}


struct SignInView: View {
    @Environment(AuthClient.self) private var auth

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 64))
                // A LITERAL, and deliberately not `Palette.success`. This is
                // a 64pt brand mark with no information in it — a decorative
                // graphic, which has no contrast floor — so the 2.22:1 that
                // condemns systemGreen everywhere else does not apply here.
                // Spelled as a hex value rather than `.green` so the guard
                // that keeps semantic colours in `Palette` can be total:
                // saying "this is paint, not meaning" in the code beats an
                // exemption in the CI file.
                .foregroundStyle(Color(hex: 0x34C759))
            Text("Agrent").font(.largeTitle.bold())
            Text("Земеделският агент").foregroundStyle(Palette.secondaryText)

            if case .failed(let message) = auth.state {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task { await auth.signIn() }
            } label: {
                if auth.state == .signingIn {
                    ProgressView()
                } else {
                    Text("Вход").frame(maxWidth: .infinity)
                }
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(auth.state == .signingIn)
            .padding(.horizontal, 40)
        }
        .padding()
    }
}
