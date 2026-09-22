import SwiftUI

/// An honest placeholder for a tab whose screen does not exist yet.
///
/// Deliberately NOT stubbed with sample rows. A fake entry reads exactly like a
/// real one, and the first person to open the tab files a bug about data that
/// was never there — or worse, believes it. An empty screen that says
/// "Предстои" cannot be mistaken for anything.
struct ComingSoonView: View {
    let title: String

    var body: some View {
        NavigationStack {
            EmptyState(
                "Предстои",
                icon: "hammer",
                message: "Този раздел не е наличен в приложението. Използвайте уеб приложението."
            )
            .navigationTitle(title)
            .appMenu()
        }
    }
}
