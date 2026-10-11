import SwiftUI

/// «Профилът Ви е заявен за изтриване» — the only screen while this account's
/// deletion is pending (agrent-ios#281; agri-saas #1597).
///
/// ── Explicit, by the owner's ruling (2026-10-11) ──
///
/// Signing in does not cancel a deletion: a sign-in can happen without a
/// decision — Google's sign-in is often one tap — and must not undo one. So
/// the person signs in, lands here, and chooses: «Възстанови профила», which
/// cancels it and opens the app, or Изход, which leaves it as it is. Nothing
/// else in the app opens meanwhile: the account is frozen, which is what
/// the person asked for.
///
/// ── What restoring does not restore ──
///
/// The request signed the person out everywhere, and cancelling does not
/// bring those sessions back — said here, so a second phone asking for a
/// sign-in is not a surprise.
///
/// ── When it cannot be restored ──
///
/// Erased already, or suspended by a moderator (a termination runs the same
/// erasure and the person cannot cancel it): the refusal is said and only
/// Изход is left (`AuthClient.restoreRefused`). A suspended account should
/// not reach this screen at all — `/me` refuses it — so that is defence, not
/// the design.
struct DeletionPendingView: View {
    let erasesAt: Date?

    @Environment(AuthClient.self) private var auth
    @State private var confirmingSignOut = false

    private typealias Words = AccountDeletionText

    var body: some View {
        ScrollableState {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(Words.pendingTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Words.pending(erasesAt: erasesAt))
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)

                if let error = auth.restoreError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Palette.error)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    if !auth.restoreRefused {
                        Button {
                            Task { await auth.restoreAccount() }
                        } label: {
                            if auth.restoringAccount {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .accessibilityLabel(Words.restoring)
                            } else {
                                Text(Words.restore)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .prominentButton()
                        .disabled(auth.restoringAccount)
                        .accessibilityInputLabels(A11y.Spoken.restoreAccount)
                    }

                    // The one question any Изход asks (`SignOutConfirmation`).
                    // Leaving keeps the deletion as it is.
                    Button {
                        confirmingSignOut = true
                    } label: {
                        Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Palette.destructive)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(auth.restoringAccount)
                    .accessibilityInputLabels(A11y.Spoken.signOut)
                    .signOutConfirmation(isPresented: $confirmingSignOut)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding()
        }
        // A refusal is said, not only shown — at high priority, because the
        // same update swaps the spinner back under VoiceOver's cursor.
        .onChange(of: auth.restoreError) { _, error in
            guard let error else { return }
            var line = AttributedString(error)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
    }
}
