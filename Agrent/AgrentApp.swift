import SwiftUI

@main
struct AgrentApp: App {
    @State private var auth = AuthClient()

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
    var body: some View {
        TabView {
            JournalListView()
                .tabItem { Label("Дневник", systemImage: "book.closed") }

            CalculatorView()
                .tabItem { Label("Калкулатор", systemImage: "plusminus") }

            ExchangeView()
                .tabItem { Label("Борса", systemImage: "arrow.left.arrow.right") }

            LocationsView()
                .tabItem { Label("Локации", systemImage: "map") }

            ComingSoonView(title: "Админ")
                .tabItem { Label("Админ", systemImage: "person.2") }
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
