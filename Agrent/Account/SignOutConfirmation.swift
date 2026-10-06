import SwiftUI

/// The ONE question before Изход, wherever Изход is.
///
/// ── Why it asks at all ──
///
/// Owner, 2026-10-06. Изход is not cheap to undo: signing back in goes through
/// the browser and Google, which in a field may not be possible, and the
/// session's cached data is purged with it (`SessionReset`).
///
/// ── Why the menu asks too ──
///
/// Изход stays in the menu, where it has been since the menu was built and
/// where the web keeps it (`user-menu.tsx`: «Профил», then «Изход» last), and
/// where `UserMessage`'s session-expired text tells a farmer to find it. A
/// menu row is the EASIER one to hit by mistake, so one place asking and the
/// other not would protect the harder tap. Both use this modifier, so the
/// question cannot drift between them.
///
/// ── Named aloud ──
///
/// Both buttons carry `A11y.Spoken` input labels, as every sheet action does:
/// Voice Control listens in the device language, and on an `en_BG` phone
/// «Изход» cannot be said.
struct SignOutConfirmation: ViewModifier {
    @Binding var isPresented: Bool

    @Environment(AuthClient.self) private var auth
    @State private var outbox = OutboxStore.shared

    func body(content: Content) -> some View {
        content.confirmationDialog(Self.title, isPresented: $isPresented, titleVisibility: .visible) {
            // `AuthClient.signOut` is the whole of it: #142's hygiene
            // (`SessionReset`) and the server revoke live there, not here.
            Button("Изход", role: .destructive) { auth.signOut() }
                .accessibilityInputLabels(A11y.Spoken.signOut)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text(Self.message(unsent: !outbox.pending.isEmpty))
        }
    }

    static let title = "Изход от профила?"

    /// What Изход costs, said before it happens.
    ///
    /// Queued operations are PARKED, not dropped (`SessionReset`): they stay
    /// on this phone stamped with this account and come back when it signs
    /// back in. A farmer with records waiting would otherwise reasonably fear
    /// that leaving throws them away — so when there are any, the question
    /// says they are safe. "Come back", not "will be sent": a refused item is
    /// parked too, and it will not be sent.
    static func message(unsent: Bool) -> String {
        let base = "За да продължите, ще трябва да влезете отново."
        guard unsent else { return base }
        return base + " Неизпратените записи остават на телефона и ще бъдат тук, "
            + "когато влезете отново."
    }
}

extension View {
    func signOutConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(SignOutConfirmation(isPresented: isPresented))
    }
}
