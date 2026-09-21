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

            ComingSoonView(title: "Борса")
                .tabItem { Label("Борса", systemImage: "arrow.left.arrow.right") }

            ComingSoonView(title: "Локации")
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
                    .font(.footnote)
                    .foregroundStyle(.red)
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
