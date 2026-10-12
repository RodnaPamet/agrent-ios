import SwiftUI

/// «Достъпът до профила Ви е спрян» — the only screen while this account is
/// suspended (agrent-ios#283; agri-saas P5.9, #1665, #1670).
///
/// ── One screen, not an error on every screen ──
///
/// A suspended account still signs in: the server checks the suspension on
/// every request, not at the door. Before this screen the app opened the
/// farm and every tab failed with the same sentence. The server treats the
/// refusal as final — signing in again meets it again — so this replaces
/// the farm, as the terms and a pending deletion do.
///
/// ── The same words as the web's `/suspended` ──
///
/// Title and body are the web page's (agri-saas #1665), so the two clients
/// never say different things about the same account. What both leave out,
/// on purpose:
///   · the reason — usually there is none to show: a suspension creates no
///     statement of reasons by itself, and one that is queued may not have
///     been delivered (agri-saas #1667);
///   · a pointer to an email, for the same reason: «we sent you» cannot be
///     true at the moment this screen appears;
///   · an appeal — there is no appeal surface, and a control that does
///     nothing is worse than none here;
///   · a redirect onward — the session is valid, so it would only land here
///     again.
///
/// ── Cancelling a deletion of their own ──
///
/// A person who asked to be deleted and was then suspended may still cancel
/// that deletion (agri-saas #1670). `/me`'s refusal carries `erasesAt` only
/// then — never for a moderator's termination, which they cannot cancel —
/// so «Отмени изтриването» appears only with a date. Cancelling does not
/// lift the suspension, and the screen says so before and after: that is
/// the part a farmer would otherwise get wrong.
///
/// «Отмени», not «Спри»: the web's own word for it (`privacy.deleteRequest`),
/// and «спирам» is already the suspension's — «спрян», «спирането» — so after
/// «Изтриването е спряно» the body's «Докато спирането е в сила» could be
/// heard as the stop just made.
struct SuspendedView: View {
    let erasesAt: Date?

    @Environment(AuthClient.self) private var auth
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var foreground = ForegroundReturn()
    @State private var confirmingSignOut = false
    /// Where VoiceOver is put: on the title once the screen swap settles, or
    /// on the notice when the screen arrives saying a deletion was cancelled;
    /// on the notice again when the cancel lands here, because the button the
    /// cursor was on is gone; on Изход when a final refusal takes it away.
    @AccessibilityFocusState private var titleFocused: Bool
    @AccessibilityFocusState private var noticeFocused: Bool
    @AccessibilityFocusState private var signOutFocused: Bool

    private typealias Words = AccountSuspensionText

    /// The person's own deletion can still be cancelled from here.
    private var canCancel: Bool { erasesAt != nil && !auth.cancelRefused }

    var body: some View {
        ScrollableState {
            VStack(spacing: 20) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(Words.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(Words.body)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)

                if let erasesAt, canCancel {
                    Text(Words.deletionPending(erasesAt: erasesAt))
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                }

                if let notice = auth.suspensionNotice {
                    Text(notice)
                        .multilineTextAlignment(.center)
                        .accessibilityFocused($noticeFocused)
                }

                if let error = auth.cancelError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Palette.error)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    if canCancel {
                        Button {
                            Task { await auth.cancelDeletion() }
                        } label: {
                            if auth.cancellingDeletion {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .accessibilityLabel(Words.cancelling)
                            } else {
                                Text(Words.cancel)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .prominentButton()
                        .disabled(auth.cancellingDeletion)
                        .accessibilityInputLabels(A11y.Spoken.cancelDeletion)
                    }

                    // The one question any Изход asks (`SignOutConfirmation`).
                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Palette.destructive)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(auth.cancellingDeletion)
                    .accessibilityInputLabels(A11y.Spoken.signOut)
                    .accessibilityFocused($signOutFocused)
                    .signOutConfirmation(isPresented: $confirmingSignOut)
                }
                .controlSize(.large)
            }
            // None of the 24 at the accessibility sizes: there «стопанството»
            // alone is wider than what is left on any phone smaller than a
            // Max, and broke mid-word.
            .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : 24)
            .padding()
        }
        .task {
            // Swapped in while the app was in the background — a refusal
            // answering after the person left — this view never saw that
            // phase, and the first return would not count as one.
            if scenePhase == .background { _ = foreground.isReturn(to: .background) }
            try? await Task.sleep(for: .milliseconds(600))
            if auth.suspensionNotice != nil { noticeFocused = true } else { titleFocused = true }
        }
        // A launch on a suspended pair asks `/me` once; a sign-in just did.
        .task { await auth.suspendedScreenAppeared() }
        // And every return to the foreground: a suspension can be lifted
        // while the phone is in a pocket, and nothing else would notice.
        .onChange(of: scenePhase) { _, phase in
            if foreground.isReturn(to: phase) {
                Task { await auth.recheckSuspension() }
            }
        }
        // The cancel landed: «Отмени изтриването» is gone from under the
        // cursor, and the notice says what happened — the deletion cancelled,
        // the access still not back.
        .onChange(of: auth.suspensionNotice) { _, notice in
            if notice != nil { noticeFocused = true }
        }
        .onChange(of: auth.cancelRefused) { _, refused in
            if refused { signOutFocused = true }
        }
        // A refusal is said, not only shown — at high priority, because the
        // same update swaps the spinner back under VoiceOver's cursor.
        .onChange(of: auth.cancelError) { _, error in
            guard let error else { return }
            var line = AttributedString(error)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
    }
}

/// The suspended screen's words. Title and body are agri-saas's
/// `suspended.title` / `suspended.body` (#1665), word for word.
enum AccountSuspensionText {
    static let title = "Достъпът до профила Ви е спрян"
    static let body = "Докато спирането е в сила, не можете да отваряте стопанството си. "
        + "Всичко вече записано се запазва."
    static let cancel = "Отмени изтриването"
    static let cancelling = "Отменяне на изтриването"
    static let deletionCancelled = "Изтриването е отменено. Достъпът до профила остава спрян."

    /// The person's own deletion, with the server's date, and — before they
    /// choose — that cancelling it does not bring the farm back.
    static func deletionPending(erasesAt: Date) -> String {
        "Заявили сте изтриване на профила. Той ще бъде изтрит на \(BgDate.fullEndingSentence(erasesAt)) "
            + "Можете да отмените изтриването, но достъпът до профила ще остане спрян."
    }
}
