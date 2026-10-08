import AuthenticationServices
import SwiftUI

@main
struct AgrentApp: App {
    @State private var auth = AuthClient()

    /// BEFORE ANY SCENE EXISTS, because the defect it fixes is paid by the
    /// first Bulgarian string UIKit measures — and on this app that can be
    /// the confirmation button on a write with no undo. See
    /// `BulgarianLayout`.
    init() {
        // FIRST, before any text is laid out: Bulgarian at the head of the
        // app's language list, so every piece of text this app draws is
        // set in Bulgarian letterforms on any phone (#205). Ahead of
        // `BulgarianLayout`, so its priming measures those shapes.
        BulgarianLetterforms.install()
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
                case .termsPending:
                    // Nothing of a farm or a person can be read until the
                    // terms are accepted — see `TermsAPI` (#193).
                    TermsAcceptanceView()
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
            // BULGARIAN LETTERFORMS ON EVERY PHONE (#205; owner, 2026-10-08).
            //
            // Since #201 the bundle's only language is `bg`, so text that
            // goes through localisation — every literal `Text("…")` — set in
            // SF Pro's Bulgarian shapes (д like a g, т like an m), while text
            // from a `String` followed the PHONE's language list. On a phone
            // that lists no Bulgarian, one screen carried both.
            //
            // `BulgarianLetterforms` (in `init`) is what fixes that everywhere,
            // sheets and alerts included. This is the explicit layer for
            // SwiftUI's text on the main screens, which holds even if the
            // system ever stops honouring the app's own language list.
            .typesettingLanguage(Locale.Language(identifier: "bg"))
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
    /// Here, not shared: `FarmGate` rebuilds this view per farm, so every
    /// farm's tabs start at their roots (see `AppRouter`).
    @State private var router = AppRouter(bar: BottomTabsStore.shared.bottomTabs)
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
            // Selection through the router (#194): a re-tap of the selected
            // tab arrives as a write of the same value, which pops it.
            TabView(selection: $router.tab) {
                ForEach(tabs.bottomTabs) { surface in
                    surface.screen
                        // The root's `RoutedStack` keeps its path in the
                        // router under this surface.
                        .environment(\.routedSurface, surface)
                        .tabItem { Label(surface.label, systemImage: surface.icon) }
                        // How many conversations have something unread
                        // (PARITY GAP 7) — THREADS, not messages; 0 draws no
                        // badge. The web has none; the owner asked for one.
                        // When Борса is not on the bar the app menu's row
                        // carries the count instead.
                        .badge(surface == .exchange ? unread.count : 0)
                        .tag(surface)
                }
            }
            .onChange(of: tabs.bottomTabs) { _, bar in router.adoptBar(bar) }
        }
        .environment(router)
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
    @Environment(\.colorScheme) private var colorScheme
    /// Apple's button takes ANY height it is offered — with only a minimum it
    /// filled the screen below the other two. So it gets one: the HIG's 50 at
    /// the default text size, growing with it like the buttons above, capped
    /// where a taller black bar stops helping anyone read it.
    @ScaledMetric(relativeTo: .body) private var appleButtonHeight: CGFloat = 50

    var body: some View {
        // Scrollable when it has to be: with three buttons, AX5 runs past the
        // screen, and a VStack that cannot scroll truncates instead —
        // «Земеделския…» — or pushes a way in off the bottom.
        ScrollableState {
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
            Text("Земеделският агент")
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)

            if case .failed(let message) = auth.state {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // ── Three ways in (agrent-ios#193, P4.4) ──
            //
            // Google first and prominent: it is how every account so far was
            // made. Microsoft through the same browser flow — the server's
            // other configured provider. Apple through Apple's OWN button,
            // which the guidelines require as-is and which App Review
            // requires beside any third-party sign-in. It labels itself in
            // the APP's declared language — Bulgarian since agrent-ios#201,
            // so «Вход с Apple» even on a phone set to English. Its Voice
            // Control names stay in both: Voice Control listens in its own
            // language setting, not the app's. Until the server has an Apple
            // audience, a tap ends in «…все още не е включен», and Google and
            // Microsoft are untouched by it.
            VStack(spacing: 12) {
                Button {
                    Task { await auth.signIn(with: .google) }
                } label: {
                    if auth.signingInVia == .google {
                        ProgressView().accessibilityLabel(SignInText.signingIn)
                    } else {
                        // Wraps rather than truncating: at AX5 the prominent
                        // style cut it to «Вход с…».
                        Text(SignInText.google)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .prominentButton()
                .accessibilityInputLabels(A11y.spokenNames(SignInText.google, "Sign in with Google"))

                Button {
                    Task { await auth.signIn(with: .microsoft) }
                } label: {
                    if auth.signingInVia == .microsoft {
                        ProgressView().accessibilityLabel(SignInText.signingIn)
                    } else {
                        Text(SignInText.microsoft)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityInputLabels(A11y.spokenNames(SignInText.microsoft, "Sign in with Microsoft"))

                SignInWithAppleButton(.signIn) { request in
                    auth.prepareAppleRequest(request)
                } onCompletion: { result in
                    Task { await auth.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: min(appleButtonHeight, 88))
                .accessibilityInputLabels(A11y.spokenNames(SignInText.apple, "Sign in with Apple"))

                // Apple's button cannot show a spinner of its own.
                if auth.signingInVia == .apple {
                    ProgressView().accessibilityLabel(SignInText.signingIn)
                }
            }
            .controlSize(.large)
            .disabled(auth.state == .signingIn)
            .padding(.horizontal, 40)
        }
        .padding()
        }
        // A refusal is said, not only shown: the words appear above buttons a
        // VoiceOver user's focus is on — and `email_required` tells them what
        // to do in Settings.
        .onChange(of: auth.state) { _, state in
            if case .failed(let message) = state {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

enum SignInText {
    static let google = "Вход с Google"
    static let microsoft = "Вход с Microsoft"
    static let apple = "Вход с Apple"
    static let signingIn = "Влизане"
}
