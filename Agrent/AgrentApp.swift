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
        Appearance.install()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch auth.state {
                case .signedIn:
                    MainTabView()
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
    @Environment(\.scenePhase) private var scenePhase

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
                if let me = await CurrentUserStore.shared.load() {
                    tabs.adopt(me.bottomTabOrder, isOperator: me.isOperator)
                }
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


struct SignInView: View {
    @Environment(AuthClient.self) private var auth

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Agrent").font(.largeTitle.bold())
            Text("Земеделският агент").foregroundStyle(.secondary)

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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(auth.state == .signingIn)
            .padding(.horizontal, 40)
        }
        .padding()
    }
}
