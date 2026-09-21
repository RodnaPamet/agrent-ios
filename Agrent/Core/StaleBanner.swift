import SwiftUI

/// Shown whenever what is on screen came off disk rather than off the network.
///
/// Not dismissible, and deliberately not styled as an error: the data below it
/// is real, it is simply old, and the operator is the one who knows whether
/// "преди 3 дни" is good enough for the decision they are about to make.
///
/// Shared rather than per-screen so that every cached surface says the same
/// thing the same way — a staleness warning that looks different on each tab
/// teaches people to ignore it.
struct StaleBanner: View {
    let age: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Последно обновено \(age)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.18))
    }
}
